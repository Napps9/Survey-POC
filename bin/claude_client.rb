# frozen_string_literal: true

# Shared Anthropic REST plumbing for bin/estimate_points and
# bin/trello_week_summary. Not executable on its own — require_relative it.

require "net/http"
require "uri"
require "json"

module ClaudeClient
  DEFAULT_MODEL = ENV.fetch("CLAUDE_MODEL_FAST", "claude-haiku-4-5-20251001")

  def self.http_for(uri)
    # Same proxy-detection gap as trello_client: Net::HTTP's :ENV proxy only
    # reads http_proxy, never https_proxy — read it directly.
    proxy_env = ENV["https_proxy"] || ENV["HTTPS_PROXY"]
    proxy_uri = URI(proxy_env) if proxy_env
    http = Net::HTTP.new(uri.host, uri.port, proxy_uri&.host, proxy_uri&.port)
    http.use_ssl = true
    # A hung call must not hang an unattended weekly run indefinitely.
    http.read_timeout = 120
    http
  end

  # Generic POST /v1/messages. Optional keys (system, temperature, tools,
  # tool_choice) are serialized only when given — absent, not null — so the
  # request stays valid for models that reject explicit sampling params.
  def self.messages(api_key:, model:, max_tokens:, user_message:, system: nil,
                    temperature: nil, tools: nil, tool_choice: nil)
    body = {
      model: model,
      max_tokens: max_tokens,
      messages: [ { role: "user", content: user_message } ]
    }
    body[:system] = system if system
    body[:temperature] = temperature if temperature
    body[:tools] = tools if tools
    body[:tool_choice] = tool_choice if tool_choice

    uri = URI("https://api.anthropic.com/v1/messages")
    request = Net::HTTP::Post.new(uri)
    request["x-api-key"] = api_key
    request["anthropic-version"] = "2023-06-01"
    request["content-type"] = "application/json"
    request.body = JSON.generate(body)
    response = http_for(uri).start { |h| h.request(request) }
    raise "Anthropic API error #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end

  # The first text content block's text, or nil.
  def self.first_text(response)
    block = Array(response["content"]).find { |b| b["type"] == "text" }
    block && block["text"]
  end
end
