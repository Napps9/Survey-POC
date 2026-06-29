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
  TIMEOUT_SECS   = 6

  # context → which orientation to search for and which src crop to store.
  ORIENTATION_FOR = { background: "landscape", card: "portrait", swipe: "landscape" }.freeze
  SRC_FOR         = { background: "landscape", card: "portrait", swipe: "landscape" }.freeze

  class << self
    def api_key
      ENV["PEXELS_API_KEY"].presence || ENV["PEXELS"].presence
    end

    def configured?
      api_key.present?
    end

    # The slot-appropriate, pre-cropped image URL for a Pexels photo hash.
    # Falls back to the original if the expected crop is missing.
    def url_for(photo, context)
      src = photo["src"] || {}
      key = SRC_FOR[context.to_sym] || "large"
      src[key].presence || src["original"]
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
    Rails.logger.error("[PexelsClient] #{e.class}: #{e.message}")
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
