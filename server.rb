# frozen_string_literal: true

require 'sinatra'
require 'logger'
require 'json'
require 'openssl'
require 'octokit'
require 'jwt'
require 'time' # This is necessary to get the ISO 8601 representation of a Time object
require 'dotenv/load'

require_relative 'github_graphql_api'

set :bind, '0.0.0.0'
set :port, 3000

class ReviewerAutoAssign < Sinatra::Application
  # Never, ever, hardcode app tokens or other secrets in your code!
  # Always extract from a runtime source, like an environment variable.

  # Notice that the private key must be in PEM format, but the newlines should be stripped and replaced with
  # the literal `\n`. This can be done in the terminal as such:
  # export GITHUB_PRIVATE_KEY=`awk '{printf "%s\\n", $0}' private-key.pem`
  PRIVATE_KEY = OpenSSL::PKey::RSA.new(ENV['GITHUB_PRIVATE_KEY'].gsub('\n', "\n")) # convert newlines

  # You set the webhook secret when you create your app. This verifies that the webhook is really coming from GH.
  WEBHOOK_SECRET = ENV['GITHUB_WEBHOOK_SECRET']

  # Get the app identifier—an integer—from your app page after you create your app. This isn't actually a secret,
  # but it is something easier to configure at runtime.
  APP_IDENTIFIER = ENV['GITHUB_APP_IDENTIFIER']

  ########## Configure Sinatra
  #
  # Let's turn on verbose logging during development
  #
  configure :development do
    set :logging, Logger::DEBUG
  end

  ########## Before each request to our app
  #
  # Before each request to our app, we want to instantiate an Octokit client. Doing so requires that we construct a JWT.
  # https://jwt.io/introduction/
  # We have to also sign that JWT with our private key, so GitHub can be sure that
  #  a) it came from us
  #  b) it hasn't been altered by a malicious third party
  #
  before do
    payload = {
      # The time that this JWT was issued, _i.e._ now.
      iat: Time.now.to_i,

      # How long is the JWT good for (in seconds)?
      # Let's say it can be used for 10 minutes before it needs to be refreshed.
      # TODO we don't actually cache this token, we regenerate a new one every time!
      exp: Time.now.to_i + (10 * 60),

      # Your GitHub App's identifier number, so GitHub knows who issued the JWT, and know what permissions
      # this token has.
      iss: APP_IDENTIFIER
    }

    # Cryptographically sign the JWT
    jwt = JWT.encode(payload, PRIVATE_KEY, 'RS256')

    # Create the Octokit client, using the JWT as the auth token.
    # Notice that this client will _not_ have sufficient permissions to do many interesting things!
    # We might, for particular endpoints, need to generate an installation token (using the JWT), and instantiate
    # a new client object. But we'll cross that bridge when/if we get there!
    @client ||= Octokit::Client.new(
      bearer_token: jwt,
      api_endpoint: "https://#{ENV['GITHUB_HOST']}/api/v3/"
    )
  end

  ########## Events
  #
  # This is the webhook endpoint that GH will call with events, and hence where we will do our event handling
  #

  post '/' do
    request.body.rewind
    payload_raw = request.body.read # We need the raw text of the body to check the webhook signature
    begin
      payload = JSON.parse payload_raw
    rescue StandardError
      payload = {}
    end

    # Check X-Hub-Signature to confirm that this webhook was generated by GitHub, and not a malicious third party.
    # The way this works is: We have registered with GitHub a secret, and we have stored it locally in WEBHOOK_SECRET.
    # GitHub will cryptographically sign the request payload with this secret. We will do the same, and if the results
    # match, then we know that the request is from GitHub (or, at least, from someone who knows the secret!)
    # If they don't match, this request is an attack, and we should reject it.
    # The signature comes in with header x-hub-signature, and looks like "sha1=123456"
    # We should take the left hand side as the signature method, and the right hand side as the
    # HMAC digest (the signature) itself.
    their_signature_header = request.env['HTTP_X_HUB_SIGNATURE'] || 'sha1='
    method, their_digest = their_signature_header.split('=')
    our_digest = OpenSSL::HMAC.hexdigest(method, WEBHOOK_SECRET, payload_raw)
    halt 401 unless their_digest == our_digest

    # Determine what kind of event this is, and take action as appropriate
    # TODO we assume that GitHub will always provide an X-GITHUB-EVENT header in this case, which is a reasonable
    #      assumption, however we should probably be more careful!
    logger.debug "---- received event #{request.env['HTTP_X_GITHUB_EVENT']}"
    logger.debug "----         action #{payload['action']}" unless payload['action'].nil?

    case request.env['HTTP_X_GITHUB_EVENT']
    when 'pull_request'
      if payload['action'] == 'opened'
        if payload['pull_request']['requested_reviewers'].empty?
          assign_reviewer(payload)
        end
      end
    end

    'ok' # we have to return _something_ ;)
  end

  ########## Helpers
  #
  # These functions are going to help us do some tasks that we don't want clogging up the happy paths above, or
  # that need to be done repeatedly. You can add anything you like here, really!
  #

  SUGGESTED_REVIEWERS_QUERY = GithubGraphQLAPI::Client.parse <<-'GRAPHQL'
    query($owner:String!, $repo_name:String!, $pr_number:Int!) {
        repository(owner: $owner, name: $repo_name) {
          pullRequest(number: $pr_number) {
            id
            suggestedReviewers {
              isAuthor
              isCommenter
              reviewer {
                id
              }
            }
          }
          assignableUsers(first:100) {
            edges {
              node {
                id
              }
            }
          }
        }
    }
  GRAPHQL

  REQUEST_REVIEW = GithubGraphQLAPI::Client.parse <<-'GRAPHQL'
    mutation($pr_id:ID!, $user_id:ID!) {
      requestReviews(input: {pullRequestId: $pr_id, userIds: [$user_id]}) {
        pullRequest{
          title
        }
      }
    }
  GRAPHQL

  helpers do
    def access_token(payload)
      installation_id = payload['installation']['id']
      @client.create_app_installation_access_token(installation_id)[:token]
    end

    def fetch_pr(payload)
      GithubGraphQLAPI::Client.query(
          SUGGESTED_REVIEWERS_QUERY,
          variables: {
              owner: payload['repository']['owner']['login'],
              repo_name: payload['repository']['name'],
              pr_number: payload['number']
          },
          context: { token: access_token(payload) }
      )
    end

    def assign_reviewer(payload)
      logger.debug 'Handling the event that we care about!'

      response = fetch_pr(payload)

      # Search reviewers
      assign_id = if response.data.repository.pull_request.suggested_reviewers.empty?
                    # from repository users
                    assignable_users = response.data.repository.assignable_users.edges.map do |edge|
                      edge.node.id
                    end
                    assignable_users.sample
                  else
                    # from suggested reviewers
                    response.data.repository.pull_request.suggested_reviewers.sample.id
                  end

      if assign_id
        GithubGraphQLAPI::Client.query(
          REQUEST_REVIEW,
          variables: {
            pr_id: response.data.repository.pull_request.id,
            user_id: assign_id
          },
          context: { token: access_token(payload) }
        )
      end

      true
    end
  end

  run! if $PROGRAM_NAME == __FILE__
end
