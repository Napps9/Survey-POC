# The week's commits, read from the public GitHub API.
#
# Unauthenticated on purpose: the repo is public and this runs once a week,
# nowhere near the 60-requests-an-hour anonymous limit. Adding a token would
# mean another production secret for data anyone can already read.
#
# The URL is built from a constant and an ENV var — nothing user-supplied
# reaches it, and redirects are never followed.
#
# Every failure returns [] rather than raising: a newsletter with no feature
# list is a thin newsletter, but a Thursday with no draft at all is a missed
# week. The caller decides what to say about an empty result.
require "net/http"
require "uri"
require "json"

module Comms
  module GithubCommits
    module_function

    API_HOST     = "https://api.github.com".freeze
    BRANCH       = "Main".freeze
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10

    def since(time, repo: ENV.fetch("NEWSLETTER_REPO", "Napps9/Survey-POC"))
      uri = URI("#{API_HOST}/repos/#{repo}/commits")
      uri.query = URI.encode_www_form(sha: BRANCH, since: time.utc.iso8601, per_page: 100)

      response = get(uri)
      return [] unless response.is_a?(Net::HTTPSuccess)

      body = JSON.parse(response.body)
      body.is_a?(Array) ? body : []
    rescue => e
      ErrorReporting.report("Comms::GithubCommits", e, repo: repo)
      []
    end

    def get(uri)
      http = build_http(uri)
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      request = Net::HTTP::Get.new(uri)
      # GitHub rejects requests without one.
      request["User-Agent"] = "VertoNow-Newsletter"
      request["Accept"] = "application/vnd.github+json"

      http.start { |h| h.request(request) }
    end

    def build_http(uri)
      # Net::HTTP's :ENV proxy detection only reads http_proxy, never
      # https_proxy — same reason bin/trello_client.rb reads it directly.
      proxy = ENV["https_proxy"] || ENV["HTTPS_PROXY"]
      proxy_uri = URI(proxy) if proxy.present?

      http = Net::HTTP.new(uri.host, uri.port, proxy_uri&.host, proxy_uri&.port)
      http.use_ssl = true
      http
    end
  end
end
