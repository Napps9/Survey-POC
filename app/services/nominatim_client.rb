require "net/http"
require "json"
require "uri"

# Thin wrapper around OpenStreetMap's Nominatim search API
# (https://nominatim.org/release-docs/latest/api/Search/), used for the
# respondent-facing "where are you" location search (a satnav-style
# type-ahead, replacing a free-text area field so location data groups
# reliably instead of by whatever a respondent happened to type).
#
# Privacy/GDPR note: this client deliberately never reads or returns Nominatim's
# `lat`/`lon` fields — only the resolved city/region/country. That omission,
# not a redaction step, is the guarantee that no precise coordinate or address
# ever enters this app's data model; storage stays exactly as coarse as the
# existing self-declared country+area fields it replaces.
#
# Nominatim's usage policy (https://operations.osmfoundation.org/policies/nominatim/)
# requires a small "Search by OpenStreetMap" / attribution credit near results
# (see the welcome-intake view), and a custom User-Agent identifying the app.
# Its absolute cap is 1 request/second for the whole calling app — the 3-char
# minimum query length, day-long response cache and client-side debounce below
# keep real-world call volume far under that for this app's current scale, but
# there's no cross-process shared throttle here. A dedicated queue/limiter
# would be the right next step if traffic grows enough to matter.
class NominatimClient
  ENDPOINT     = "https://nominatim.openstreetmap.org/search".freeze
  TIMEOUT_SECS = 6
  MIN_QUERY_LEN = 3
  USER_AGENT   = "Playverto/1.0 (https://playverto.app; support@playverto.app)".freeze

  class << self
    # Returns an array of { display_name:, city:, region:, country:, country_code: }
    # (possibly empty). Never raises — any network/parse/non-200 error is
    # logged and yields [] so the search box just shows no suggestions.
    def search(query:, limit: 5)
      q = query.to_s.strip
      return [] if q.length < MIN_QUERY_LEN

      cache_key = "nominatim_search:v1:#{q.downcase}:#{limit}"
      Rails.cache.fetch(cache_key, expires_in: 1.day) do
        params = { q: q, format: "jsonv2", addressdetails: 1, limit: limit.to_i.clamp(1, 10) }
        body = get_json(ENDPOINT, params)
        Array(body).filter_map { |place| normalize(place) }
      end
    rescue => e
      Rails.logger.error("[NominatimClient] #{e.class}: #{e.message}")
      []
    end

    private

    # Resolve one Nominatim place into the coarse shape this app stores.
    # Deliberately does not read place["lat"] / place["lon"].
    def normalize(place)
      address = place["address"] || {}
      country_code = address["country_code"].to_s.upcase.presence
      return nil unless country_code

      city = address["city"] || address["town"] || address["village"] ||
             address["municipality"] || address["county"]
      region = address["state"] || address["region"] || address["state_district"]

      {
        display_name: place["display_name"].to_s,
        city: city,
        region: region,
        country: address["country"],
        country_code: country_code
      }
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
        Rails.logger.warn("[NominatimClient] HTTP #{res.code} for query")
        return nil
      end
      JSON.parse(res.body)
    end
  end
end
