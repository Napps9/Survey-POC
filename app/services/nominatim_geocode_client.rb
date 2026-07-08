require "net/http"
require "json"
require "uri"

# A second, narrowly-scoped Nominatim client — unlike NominatimClient (which
# deliberately never reads lat/lon, for the respondent-facing location
# search), this one's whole job is resolving an ALREADY-STORED, already
# coarse region tag (e.g. "Texas", or "Austin, Texas") back to an
# approximate coordinate, purely to place a labeled pin on the aggregate
# Results map — see SurveysController#results_compare.
#
# This is a deliberate, scoped exception to NominatimClient's "never read
# lat/lon" rule, kept as a separate class on purpose so each client's
# contract stays simple and unambiguous to a future reader:
#   - only ever called with an aggregated region tag that already exists on
#     a survey's results, never per-respondent and never at submission time;
#   - never writes anything back to a Response row — the resolved point is
#     used for display only, within the same request/response cycle;
#   - caches for a month, since a given (query, country) pair resolves to
#     the same point indefinitely.
#
# Same usage-policy obligations as NominatimClient (attribution, custom
# User-Agent, 1 req/sec cap for the whole app) — see that class's comment.
class NominatimGeocodeClient
  ENDPOINT      = "https://nominatim.openstreetmap.org/search".freeze
  TIMEOUT_SECS  = 6
  USER_AGENT    = "Playverto/1.0 (https://playverto.app; support@playverto.app)".freeze
  CACHE_TTL     = 30.days
  MIN_INTERVAL  = 1.1 # seconds between uncached requests, under Nominatim's 1 req/sec cap

  # Ask Nominatim to simplify the boundary geometry server-side before it
  # ever reaches us — 0.01 degrees (~1km) is far more detail than a map
  # zoomed to a single country needs, and keeps the response (and cache
  # entry) small without us having to bundle or simplify anything ourselves.
  POLYGON_THRESHOLD    = 0.01
  # Safety cap on top of that: an unusually complex coastline could still
  # slip through simplification with thousands of points. Past this we'd
  # rather draw no outline than ship an oversized payload or a janky path —
  # the pin alone (already returned) is still an honest fallback.
  MAX_BOUNDARY_VERTICES = 1500

  class << self
    # { lat:, lng:, boundary: [[[lng, lat], ...], ...] } or nil. `query`
    # should already be a coarse, aggregate tag — e.g. "Austin, Texas" or
    # "Western Cape" — never per-respondent data. `boundary`, when present,
    # is one or more simplified outer rings (no holes) in the tagged
    # region's own administrative shape, for drawing a real outline on the
    # results map instead of just a pin — omitted when Nominatim has no
    # polygon for the match (e.g. it only resolved to a point).
    def coordinates_for(query:, country_code: nil)
      q = query.to_s.strip
      return nil if q.blank?

      cache_key = "nominatim_geocode:v2:#{q.downcase}:#{country_code}"
      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) do
        throttle!
        params = { q: q, format: "jsonv2", limit: 1, polygon_geojson: 1, polygon_threshold: POLYGON_THRESHOLD }
        params[:countrycodes] = country_code.to_s.downcase if country_code.present?
        place = Array(get_json(ENDPOINT, params)).first
        next nil unless place
        { lat: place["lat"].to_f, lng: place["lon"].to_f, boundary: extract_boundary(place["geojson"]) }.compact
      end
    rescue => e
      Rails.logger.error("[NominatimGeocodeClient] #{e.class}: #{e.message}")
      nil
    end

    private

    # Outer rings only (no holes — irrelevant at the zoom level this draws
    # at) as [lng, lat] pairs, or nil when there's no usable polygon.
    def extract_boundary(geojson)
      return nil unless geojson.is_a?(Hash)
      rings = case geojson["type"]
      when "Polygon"      then [ geojson["coordinates"].first ]
      when "MultiPolygon" then geojson["coordinates"].map(&:first)
      end
      return nil if rings.blank?
      rings = rings.compact.reject(&:blank?)
      return nil if rings.blank? || rings.sum(&:size) > MAX_BOUNDARY_VERTICES
      rings.map { |ring| ring.map { |lng, lat| [ lng.to_f, lat.to_f ] } }
    end

    # In-process only — same acknowledged limitation as NominatimClient (see
    # its comment): no cross-worker/cross-process shared throttle here.
    def throttle!
      elapsed = @last_call_at ? Time.now - @last_call_at : MIN_INTERVAL
      sleep(MIN_INTERVAL - elapsed) if elapsed < MIN_INTERVAL
      @last_call_at = Time.now
    end

    # Isolated HTTP seam so tests can stub a canned response.
    def get_json(url, params)
      uri = URI.parse(url)
      uri.query = URI.encode_www_form(params)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = TIMEOUT_SECS
      http.read_timeout = TIMEOUT_SECS

      req = Net::HTTP::Get.new(uri)
      req["User-Agent"] = USER_AGENT
      req["Accept"]     = "application/json"

      res = http.request(req)
      unless res.is_a?(Net::HTTPSuccess)
        Rails.logger.warn("[NominatimGeocodeClient] HTTP #{res.code} for query")
        return nil
      end
      JSON.parse(res.body)
    end
  end
end
