require "net/http"
require "json"
require "uri"

# Thin wrapper around the Pexels photo search API
# (https://www.pexels.com/api/documentation/). Used in two places:
#
#   1. AssetPopulator — the auto-fill that picks a Verto's background and each
#      card's imagery. Pexels is the primary source; when it's unconfigured or
#      a query returns nothing, the populator falls back to the curated
#      verto-library/ assets.
#   2. SurveysController#pexels_search — the editor media picker's live search.
#
# Each image slot has a target aspect ratio, so we both bias the *search*
# (orientation) and pick the *pre-cropped src size* Pexels returns:
#
#   background  → landscape backdrop  → src["landscape"] (1200×627)
#   card        → tall ~9:16 panel    → src["portrait"]  (800×1200)
#   swipe       → ~3:2 statement card → src["landscape"]
#
# Key lookup is graceful (no ENV.fetch): the feature simply stays off when no
# key is set, so dev/test/CI don't need the var and never hit the network.
class PexelsClient
  ENDPOINT       = "https://api.pexels.com/v1/search".freeze
  VIDEO_ENDPOINT = "https://api.pexels.com/videos/search".freeze
  TIMEOUT_SECS   = 6

  # Storage/bandwidth-smart video selection: prefer the smallest mp4 at least
  # this wide (enough for the portrait card), and never a 4K monster.
  VIDEO_MIN_WIDTH = 700
  VIDEO_MAX_WIDTH = 1920

  # context → which orientation to bias the search toward.
  ORIENTATION_FOR = { background: "landscape", card: "portrait", swipe: "square" }.freeze

  # context → exact [width, height] crop, matching the Verto asset spec:
  #   card  — left-panel "Main Asset", 9:16 portrait (720×1280)
  #   swipe — tap-card statement, square (800×800)
  #   background — full-bleed landscape backdrop (1920×1080)
  # We build the crop from the photo's base URL using Pexels' image-CDN params
  # (the same mechanism behind their fixed `src` sizes) so the ratio is exact
  # for the slot rather than whatever pre-baked size is closest.
  CROP_FOR = { background: [ 1920, 1080 ], card: [ 720, 1280 ], swipe: [ 800, 800 ] }.freeze
  DEFAULT_CROP = [ 800, 1200 ].freeze

  class << self
    def api_key
      ENV["PEXELS_API_KEY"].presence || ENV["PEXELS"].presence
    end

    def configured?
      api_key.present?
    end

    # The slot-appropriate, exactly-cropped image URL for a Pexels photo hash.
    def url_for(photo, context)
      src  = photo["src"] || {}
      base = src["original"].presence
      # No base URL to crop from — fall back to a pre-baked size.
      return (src["large"].presence || src.values.find(&:present?)) unless base

      w, h = CROP_FOR[context.to_sym] || DEFAULT_CROP
      sep  = base.include?("?") ? "&" : "?"
      "#{base}#{sep}auto=compress&cs=tinysrgb&fit=crop&w=#{w}&h=#{h}"
    end

    # Pick a streamable mp4 URL from a Pexels video hash — the smallest file
    # that's still sharp enough for the card, capped well below 4K so we never
    # stream a huge file. Returns nil if the video has no usable mp4.
    def video_file_url(video)
      files = Array(video["video_files"]).select do |f|
        f["file_type"].to_s == "video/mp4" && f["link"].present?
      end.sort_by { |f| f["width"].to_i }
      return nil if files.empty?

      capped = files.reject { |f| f["width"].to_i > VIDEO_MAX_WIDTH }.presence || files
      (capped.find { |f| f["width"].to_i >= VIDEO_MIN_WIDTH } || capped.last)["link"]
    end

    def video_poster(video)
      video["image"].presence
    end

    # Videographer credit ({ name, url }) — same shape the photo credit uses.
    def video_credit(video)
      user = video["user"] || {}
      { "name" => user["name"].to_s.strip.presence, "url" => user["url"].to_s.strip.presence }
    end
  end

  def initialize(api_key: self.class.api_key)
    @api_key = api_key
  end

  # Returns the parsed `photos` array (possibly empty). Never raises — any
  # network/parse/non-200 error is logged and yields [] so callers degrade to
  # their fallback instead of breaking Verto creation or the editor.
  def search(query:, orientation: nil, per_page: 30, page: 1)
    q = query.to_s.strip
    return [] if q.blank? || @api_key.blank?

    params = { query: q, per_page: per_page.clamp(1, 80), page: [ page.to_i, 1 ].max }
    params[:orientation] = orientation if orientation.present?

    body = get_json(ENDPOINT, params)
    Array(body && body["photos"])
  rescue => e
    ErrorReporting.report("PexelsClient", e)
    []
  end

  # Returns the parsed `videos` array (possibly empty). Same graceful contract
  # as #search — never raises.
  def search_videos(query:, orientation: nil, per_page: 15, page: 1)
    q = query.to_s.strip
    return [] if q.blank? || @api_key.blank?

    params = { query: q, per_page: per_page.clamp(1, 80), page: [ page.to_i, 1 ].max }
    params[:orientation] = orientation if orientation.present?

    body = get_json(VIDEO_ENDPOINT, params)
    Array(body && body["videos"])
  rescue => e
    ErrorReporting.report("PexelsClient", e)
    []
  end

  private

  # Isolated HTTP seam so tests can stub a canned response.
  def get_json(url, params)
    uri = URI.parse(url)
    uri.query = URI.encode_www_form(params)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = TIMEOUT_SECS
    http.read_timeout = TIMEOUT_SECS

    req = Net::HTTP::Get.new(uri)
    req["Authorization"] = @api_key
    req["Accept"]        = "application/json"

    res = http.request(req)
    unless res.is_a?(Net::HTTPSuccess)
      Rails.logger.warn("[PexelsClient] HTTP #{res.code} for query")
      return nil
    end
    JSON.parse(res.body)
  end
end
