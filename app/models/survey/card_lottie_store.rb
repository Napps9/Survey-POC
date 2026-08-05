# Turns a pasted LottieFiles URL into an Active Storage blob attached to a
# Verto, scrubbed and served same-origin.
#
# Hotlinking the JSON was rejected deliberately: lottie-web loads `path:` URLs
# with XHR, which the CSP's connect_src (rightly) confines to our own origin —
# and a respondent's player would depend on a third party staying up and
# keeping the file. Fetching once at paste time sidesteps all of it, and gives
# us exactly one place to scrub the animation before anything renders it.
#
# The scrub matters: the vendored lottie-web is the FULL build, expressions
# enabled — Lottie JSON can carry JS-like expression strings ("x" properties)
# that the player evaluates. Third-party animation data is executable-ish
# content until those are gone. Embedded remote asset URLs are dropped for the
# same reason the JSON itself isn't hotlinked.
class Survey
  module CardLottieStore
    # Direct animation JSON links from the LottieFiles family of hosts only —
    # the same host-allowlist posture sanitize_image_url takes with Pexels.
    SOURCE_URL = %r{\Ahttps://(?:lottie\.host|assets(?:-v\d+|\d*)\.lottiefiles\.com)/[\w\-./%]+\.json(?:\?[\w%\-=&.]*)?\z}i

    MAX_BYTES        = 2.megabytes
    FETCH_TIMEOUT    = 10 # seconds, per phase (open/read)
    CONTENT_TYPE     = "application/json"

    def self.source_url?(value)
      value.to_s.strip.match?(SOURCE_URL)
    end

    # Fetch → validate → scrub → attach. Returns the blob, or nil for any
    # failure — like CardImageStore, the reason isn't actionable to a creator
    # beyond "that link didn't work", so callers get one fallback path.
    def self.fetch_and_attach(survey, url)
      v = url.to_s.strip
      return nil unless source_url?(v)

      body = fetch(v)
      return nil if body.nil? || body.bytesize > MAX_BYTES

      json = begin
        JSON.parse(body)
      rescue JSON::ParserError
        return nil
      end
      # Minimal Lottie shape: a version and a layer list. Anything else is not
      # an animation, whatever the URL claimed.
      return nil unless json.is_a?(Hash) && json.key?("v") && json["layers"].is_a?(Array)

      scrub!(json)

      blob = ActiveStorage::Blob.create_and_upload!(
        io:           StringIO.new(JSON.generate(json)),
        # The .json extension matters: Survey::ACTIVE_STORAGE_LOTTIE_URL only
        # accepts blob paths ending in .json, so a name without it would be
        # sanitized straight back out of the card.
        filename:     "card-lottie-#{SecureRandom.hex(8)}.json",
        content_type: CONTENT_TYPE
      )
      survey.card_images.attach(blob)
      blob
    end

    # GET the URL with no redirect following (a redirect off the allowlisted
    # host is exactly what the allowlist exists to prevent). Returns the body
    # string or nil. Split out as the test seam — everything around it is pure.
    def self.fetch(url)
      uri = URI.parse(url)
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                            open_timeout: FETCH_TIMEOUT, read_timeout: FETCH_TIMEOUT) do |http|
        http.request(Net::HTTP::Get.new(uri))
      end
      res.is_a?(Net::HTTPOK) ? res.body : nil
    rescue StandardError
      nil
    end

    # In place, recursively:
    #   • drop every "x" key holding a String — that's where Lottie keeps
    #     expression code (numeric/array/hash "x" values are ordinary
    #     animation data and survive);
    #   • blank every asset "u"/"p" pair that points at a remote host, so the
    #     stored animation never phones out at render time (data: and
    #     embedded base64 payloads survive — the CSP already allows data:
    #     images).
    def self.scrub!(node)
      case node
      when Hash
        node.delete("x") if node["x"].is_a?(String)
        if node["u"].is_a?(String) && node["u"].match?(%r{\Ahttps?://}i)
          node["u"] = ""
          node["p"] = "" unless node["p"].to_s.start_with?("data:")
        end
        node["p"] = "" if node["p"].is_a?(String) && node["p"].match?(%r{\Ahttps?://}i)
        node.each_value { |v| scrub!(v) }
      when Array
        node.each { |v| scrub!(v) }
      end
      node
    end
  end
end
