# frozen_string_literal: true

# Shared Trello REST plumbing for bin/trello_log and bin/estimate_points.
# Not executable on its own — require_relative it.

require "net/http"
require "uri"
require "json"

module TrelloClient
  BOARD_ID = "ntNghZRN"

  # Fibonacci story points, mapped onto the board's 6 default (unnamed) label
  # colors instead of creating new labels.
  FIB_LABEL_COLORS = {
    "1" => "green",
    "2" => "yellow",
    "3" => "orange",
    "5" => "red",
    "8" => "purple",
    "13" => "blue"
  }.freeze

  def self.http_for(uri)
    # Net::HTTP's built-in :ENV proxy detection only reads http_proxy, never
    # https_proxy — read it directly.
    proxy_env = ENV["https_proxy"] || ENV["HTTPS_PROXY"]
    proxy_uri = URI(proxy_env) if proxy_env
    http = Net::HTTP.new(uri.host, uri.port, proxy_uri&.host, proxy_uri&.port)
    http.use_ssl = true
    http
  end

  def self.request(method, path, params)
    uri = URI("https://api.trello.com/1#{path}")
    uri.query = URI.encode_www_form(params)
    req = case method
    when :post then Net::HTTP::Post.new(uri)
    when :put then Net::HTTP::Put.new(uri)
    else Net::HTTP::Get.new(uri)
    end
    response = http_for(uri).start { |h| h.request(req) }
    raise "Trello API error #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end

  def self.attach(card_id, file_path, auth)
    abort "Screenshot not found: #{file_path}" unless File.exist?(file_path)

    uri = URI("https://api.trello.com/1/cards/#{card_id}/attachments")
    req = Net::HTTP::Post.new(uri)
    form_fields = [
      [ "key", auth[:key] ],
      [ "token", auth[:token] ],
      [ "file", File.open(file_path, "rb"), { filename: File.basename(file_path) } ]
    ]
    req.set_form(form_fields, "multipart/form-data")
    response = http_for(uri).start { |h| h.request(req) }
    raise "Trello API error #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end

  # Posts a plain-text comment on a card — used by estimate_points to leave
  # an auditable axis-score breakdown (or a manual-review flag) on the card.
  def self.comment(card_id, text, auth)
    request(:post, "/cards/#{card_id}/actions/comments", auth.merge(text: text))
  end

  # Finds the board's default label for the given points value's color and
  # names it (e.g. "5") if it isn't already, then returns the label id.
  def self.points_label_id(points, auth)
    color = FIB_LABEL_COLORS.fetch(points)
    labels = request(:get, "/boards/#{BOARD_ID}/labels", auth.merge(fields: "name,color", limit: 1000))
    label = labels.find { |l| l["color"] == color }
    raise "No \"#{color}\" label found on the board to represent #{points} points" unless label

    request(:put, "/labels/#{label['id']}", auth.merge(name: points)) unless label["name"] == points
    label["id"]
  end

  # Adds the points label to a card WITHOUT removing any labels already on
  # it (idLabels on POST /cards would replace; this is the additive form).
  def self.add_points_label(card_id, points, auth)
    label_id = points_label_id(points, auth)
    request(:post, "/cards/#{card_id}/idLabels", auth.merge(value: label_id))
    label_id
  end

  def self.find_or_create_list(list_name, auth)
    lists = request(:get, "/boards/#{BOARD_ID}/lists", auth)
    lists.find { |l| l["name"].casecmp?(list_name) } ||
      request(:post, "/boards/#{BOARD_ID}/lists", auth.merge(name: list_name))
  end
end
