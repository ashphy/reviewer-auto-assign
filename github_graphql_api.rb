# frozen_string_literal: true

require 'graphql/client'
require 'graphql/client/http'

module GithubGraphQLAPI
  # Configure GraphQL endpoint using the basic HTTP network adapter.
  HTTP = GraphQL::Client::HTTP.new("https://#{ENV['GITHUB_HOST']}/api/graphql") do
    def headers(context)
      if context[:token]
        { 'Authorization' => "bearer #{context[:token]}" }
      else
        {}
      end
    end
  end

  Schema = GraphQL::Client.load_schema('schema.json')
  Client = GraphQL::Client.new(schema: Schema, execute: HTTP)
end
