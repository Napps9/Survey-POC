require "net/http"
require "json"

# Thin read-only client for the Google Forms API. Fetches a form's structure
# with the connecting user's OAuth access token (needs the
# forms.body.readonly scope). HTTP is isolated in a private `get_json` seam so
# tests can inject a canned response without hitting the network.
class GoogleFormsClient
  API_BASE     = "https://forms.googleapis.com/v1/forms/".freeze
  OPEN_TIMEOUT = 6
  READ_TIMEOUT = 10

  class Error < StandardError; end
  class NotAuthorized < Error; end # 401/403 — token missing/expired or lacks the Forms scope
  class NotFound      < Error; end # 404 — wrong id or no access

  # Pull the form ID out of a pasted Google Forms link (or accept a bare id).
  # Editor links look like https://docs.google.com/forms/d/<ID>/edit — that
  # <ID> is what the API needs. The public responder link uses /forms/d/e/<X>/,
  # whose <X> is NOT an API form id, so we reject it with a clear message.
  def self.extract_form_id(input)
    s = input.to_s.strip
    return nil if s.empty?

    raise Error, "That looks like a public response link (…/d/e/…). Paste the form's EDIT link " \
                 "(…/forms/d/<id>/edit) instead." if s.match?(%r{/forms/d/e/})

    if (m = s.match(%r{/forms/d/([a-zA-Z0-9_\-]+)}))
      return m[1]
    end
    s.match?(/\A[a-zA-Z0-9_\-]{8,}\z/) ? s : nil
  end

  def initialize(access_token)
    @access_token = access_token
  end

  # Returns the parsed form Hash, or raises one of the errors above.
  def fetch(form_id)
    get_json("#{API_BASE}#{form_id}")
  end

  private

  def get_json(url)
    uri  = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl     = true
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT

    req = Net::HTTP::Get.new(uri)
    req["Authorization"] = "Bearer #{@access_token}"
    req["Accept"]        = "application/json"

    res = http.request(req)
    case res.code.to_i
    when 200      then JSON.parse(res.body)
    when 401, 403 then raise NotAuthorized, "Google declined the request (#{res.code}). Reconnect Google with Forms access."
    when 404      then raise NotFound, "That form wasn't found — check the link and that your Google account can open it."
    else               raise Error, "Google Forms API error (#{res.code})."
    end
  end
end
