require "anthropic"

# Checks a creator-uploaded image (a base64 data URL from the media picker) is
# PG and appropriate for the Verto's audience, using Claude vision. We can't
# word-filter uploads the way we do Pexels queries/descriptions, so this is the
# control for the upload path. Called once when an upload is applied — not on
# every autosave.
#
# Fails SAFE where sensible: unreadable/unsupported formats and an unconfigured
# API pass through (nothing to check); a configured call that errors is treated
# as "couldn't verify" by the caller and blocks the upload.
class ImageModerator
  include AnthropicHelpers

  MODEL      = ClaudeModels::FAST
  MAX_TOKENS = 256

  # Formats Claude vision can read. Uploads are downscaled to WebP/JPEG; SVGs
  # and anything exotic can't be inspected, so we let them through.
  SUPPORTED = %w[image/jpeg image/png image/gif image/webp].freeze

  TOOL = {
    name: "report_safety",
    description: "Report whether the image is safe: PG and appropriate for the audience.",
    input_schema: {
      type: "object",
      properties: {
        safe:   { type: "boolean", description: "true ONLY if the image is PG and appropriate for the stated audience." },
        reason: { type: "string",  description: "When not safe, one short sentence naming why (e.g. 'contains nudity', 'shows alcohol')." }
      },
      required: %w[safe]
    }
  }.freeze

  def self.configured?
    ENV["ANTHROPIC_API_KEY"].present?
  end

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = build_anthropic_client(api_key)
  end

  # Returns { safe: true|false, reason: "" }.
  def call(data_url:, audience_age: nil)
    media_type, data = parse_data_url(data_url)
    return { safe: true, reason: "" } if media_type.nil? || !SUPPORTED.include?(media_type)

    response = @client.messages.create(
      model:       MODEL,
      max_tokens:  MAX_TOKENS,
      system:      system_prompt(audience_age),
      tools:       [ TOOL ],
      tool_choice: { type: "tool", name: "report_safety" },
      messages: [ { role: "user", content: [
        { type: "image", source: { type: "base64", media_type: media_type, data: data } },
        { type: "text",  text: "Is this image safe to show in the survey?" }
      ] } ]
    )
    log_usage("ImageModerator", response.usage, model: MODEL)

    block = Array(response.content).find { |b| tool_use?(b) }
    out   = block ? deep_stringify(input_of(block)) : {}
    { safe: out["safe"] == true, reason: out["reason"].to_s.strip }
  end

  private

  def system_prompt(audience_age)
    audience = audience_age.to_s.strip.presence
    <<~SYS
      You are a strict content-safety reviewer for a public survey platform.
      Mark an image "safe" ONLY if it is PG: no nudity or sexual/suggestive
      content, no graphic violence or gore, no weapons used threateningly, no
      drugs or drug paraphernalia, no hate symbols.#{audience ? " The survey's audience is: #{audience}." : ""}
      For a young or children's audience, ALSO reject alcohol, smoking/vaping,
      gambling and other mature-but-legal themes. When in doubt, mark it not
      safe. Report via the report_safety tool.
    SYS
  end

  def parse_data_url(url)
    m = url.to_s.match(%r{\Adata:(image/[a-zA-Z0-9.+-]+);base64,(.+)\z}m)
    m ? [ m[1].downcase, m[2] ] : [ nil, nil ]
  end
end
