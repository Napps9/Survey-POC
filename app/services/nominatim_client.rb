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
# Provider: the public OpenStreetMap Nominatim server enforces a strict usage
# policy and, in practice, returns HTTP 403 for server-side calls from cloud /
# datacenter IPs — which is where this app runs. So when LOCATIONIQ_API_KEY is
# set the client routes searches through LocationIQ instead: a hosted Nominatim
# whose response shape is identical (so normalize/privacy below are unchanged)
# but which permits server-side use. Without the key it falls back to the public
# OSM server, keeping dev/test/CI key-free. Both instances serve OpenStreetMap
# data, so the "Search by OpenStreetMap" attribution credit near the results
# (see the welcome-intake view) stays accurate either way.
#
# A custom User-Agent identifies the app (required by both). The 3-char minimum
# query length, day-long cache of successful lookups and client-side debounce
# keep call volume low; there's no cross-process shared throttle here — a
# dedicated queue/limiter would be the right next step if traffic grows enough
# to matter.
class NominatimClient
  NOMINATIM_ENDPOINT  = "https://nominatim.openstreetmap.org/search".freeze
  # LocationIQ mirrors Nominatim's /search API; region is us1 (default) or eu1.
  LOCATIONIQ_ENDPOINT = "https://%<region>s.locationiq.com/v1/search".freeze
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

      cache_key = "geocode_search:v2:#{provider}:#{q.downcase}:#{limit}"
      cached = Rails.cache.read(cache_key)
      return cached if cached

      body    = get_json(endpoint, request_params(q, limit))
      results = Array(body).filter_map { |place| normalize(place) }
      # Only cache a real hit — never let a transient outage or a 403 poison a
      # search term with an empty list for a full day.
      Rails.cache.write(cache_key, results, expires_in: 1.day) if results.any?
      results
    rescue => e
      ErrorReporting.report("NominatimClient", e)
      []
    end

    private

    # "locationiq" when a key is configured, else the public "nominatim" server.
    def provider
      ENV["LOCATIONIQ_API_KEY"].present? ? "locationiq" : "nominatim"
    end

    def endpoint
      if provider == "locationiq"
        format(LOCATIONIQ_ENDPOINT, region: ENV.fetch("LOCATIONIQ_REGION", "us1"))
      else
        NOMINATIM_ENDPOINT
      end
    end

    # Both back ends accept the same core params; LocationIQ needs the key and
    # its own `format=json` (vs Nominatim's `jsonv2`) — the response body is the
    # same either way, so normalize below is untouched.
    def request_params(q, limit)
      params = { q: q, addressdetails: 1, limit: limit.to_i.clamp(1, 10) }
      if provider == "locationiq"
        params[:format] = "json"
        params[:key]    = ENV["LOCATIONIQ_API_KEY"]
      else
        params[:format] = "jsonv2"
      end
      params
    end

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
