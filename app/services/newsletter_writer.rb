require "anthropic"

# Turns a week of commit messages into a newsletter a customer would want to
# read. The input is developer-facing prose written for the next developer;
# the output is user-facing prose written for someone who runs surveys and has
# never seen the codebase. That translation is the whole job.
#
# Optional by construction (the lazy api_key pattern, as in SdgClassifier):
# a missing key or a failed call returns nil, and the caller falls back to
# Comms::NewsletterSource.fallback_copy. The newsletter is a draft a human
# approves — it must never be the reason a Thursday produces nothing.
#
# Commit messages are written by us, not by respondents, so no PromptSafety
# wrapping is needed here.
class NewsletterWriter
  include AnthropicHelpers

  MODEL      = ClaudeModels::DEFAULT
  MAX_TOKENS = 2000

  MAX_ITEMS       = 6
  MAX_TITLE_CHARS = 80
  MAX_BODY_CHARS  = 400
  # The campaign model keeps three at most; two alternates plus the subject
  # itself splits a small early-adopter list into groups still worth reading.
  MAX_VARIANTS    = 2

  TOOL = {
    name: "compose_newsletter",
    description: "Write this week's VertoNow customer newsletter from the week's shipped changes.",
    input_schema: {
      type: "object",
      properties: {
        subject: {
          type: "string",
          description: "Email subject line. Concrete and specific to this week's changes — not 'Your weekly update'. Under 60 characters. No emoji."
        },
        subject_variants: {
          type: "array",
          description: "Two alternative subject lines to test against the main one. Each must take a GENUINELY different angle — e.g. one naming the concrete change, one asking the question the reader has, one leading with the benefit. Same length rules. Not rewordings of each other.",
          items: { type: "string" }
        },
        preheader: {
          type: "string",
          description: "The preview line after the subject in an inbox. It is a second line of space, not a repeat: it must say something the subject does not. One sentence, under 90 characters."
        },
        intro: {
          type: "string",
          description: "Two or three warm sentences opening the email. Address the reader as 'you'. Say what this week was about in plain language."
        },
        items: {
          type: "array",
          description: "The changes worth telling a customer about, most interesting first. Merge several commits into one item when they are one improvement. Omit anything a customer could not notice — no refactors, no test-only changes, no deployment plumbing. Fewer, better items beat a complete list.",
          items: {
            type: "object",
            properties: {
              title: { type: "string", description: "What the customer can now do, in their words. Under 80 characters. Not a commit subject." },
              body: { type: "string", description: "One or two sentences: what it does for them and why it helps. Benefit first, mechanism second. Under 400 characters." }
            },
            required: %w[title body]
          }
        },
        cta_label: {
          type: "string",
          description: "Text for the single button into VertoNow. An action, e.g. 'Build your next Verto'. Under 30 characters."
        },
        sign_off: {
          type: "string",
          description: "One closing sentence. Encouraging, inviting a reply with what they'd like next."
        }
      },
      required: %w[subject subject_variants preheader intro items cta_label sign_off]
    }
  }.freeze

  SYSTEM = <<~PROMPT.freeze
    You write the weekly product newsletter for VertoNow, a platform where
    organisations build surveys ("Vertos") and collect responses.

    You are given the raw commit messages from a week of development. They are
    written for developers. Your readers are early adopters running real
    research — smart, busy, not technical about our stack, and rooting for us.

    How to write:
    - Second person. "You can now..." not "We have implemented...".
    - Lead with what it means for them, then how it works. A change nobody can
      notice does not belong in the email at all — leave it out.
    - Plain English. No jargon, no internal names (Solid Queue, Stimulus,
      migrations, Postgres), no file paths, no commit hashes.
    - Warm and encouraging, never breathless. No hype words: no "excited to
      announce", "game-changing", "revolutionary", "supercharge". No emoji.
      No exclamation marks unless one is genuinely earned.
    - Honest scale. A small fix is a small fix; do not inflate it. If the week
      was quiet, say so plainly and warmly — a short honest edition reads far
      better than a padded one.
    - Never invent a feature that is not in the commits. If you cannot tell
      what a commit did for a customer, leave it out.

    Group related commits into a single item. Six items is the ceiling; three
    strong ones are usually better than six weak ones.
  PROMPT

  def initialize(api_key: nil)
    @api_key = api_key || ENV["ANTHROPIC_API_KEY"]
  end

  def configured?
    @api_key.present?
  end

  # -> the copy hash (same shape as NewsletterSource.fallback_copy), or nil
  # when unavailable. nil is a MISSING verdict, never an empty edition.
  def call(commits, week:)
    return nil unless configured?
    return nil if Array(commits).empty?

    response = client.messages.create(
      model:      MODEL,
      max_tokens: MAX_TOKENS,
      system:     [ { type: "text", text: SYSTEM, cache_control: { type: "ephemeral" } } ],
      tools:      [ TOOL ],
      tool_choice: { type: "tool", name: TOOL[:name] },
      messages:   [ { role: "user", content: user_message(commits, week) } ],
      request_options: anthropic_request_options
    )
    log_usage("NewsletterWriter", response.usage, model: MODEL)

    block = Array(response.content).find { |b| tool_use?(b) }
    return nil unless block

    normalize(deep_stringify(input_of(block)))
  rescue => e
    # Enrichment, not the point: the fallback edition still ships.
    ErrorReporting.report("NewsletterWriter", e)
    nil
  end

  private

  def client
    @client ||= build_anthropic_client(@api_key)
  end

  def user_message(commits, week)
    lines = Array(commits).map do |c|
      body = c["body"].to_s.strip
      body.present? ? "- #{c["subject"]}\n  #{body.gsub("\n", "\n  ")}" : "- #{c["subject"]}"
    end

    <<~MSG
      Week beginning #{week.strftime("%-d %B %Y")}. #{lines.size} changes shipped.

      #{lines.join("\n\n")}
    MSG
  end

  # The model's structure is never trusted: every field is re-typed, trimmed
  # and bounded here, and anything unusable drops out.
  def normalize(raw)
    items = Array(raw["items"]).filter_map do |item|
      next unless item.is_a?(Hash)

      title = str(item["title"], MAX_TITLE_CHARS)
      next if title.blank?

      { "title" => title, "body" => str(item["body"], MAX_BODY_CHARS) }
    end.first(MAX_ITEMS)

    subject = str(raw["subject"], 140)
    # A blank subject would be refused at freeze — treat the whole reply as
    # unusable and let the caller fall back rather than ship half an edition.
    return nil if items.empty? || subject.blank?

    variants = Array(raw["subject_variants"]).filter_map { |v| str(v, 140).presence }
                                             .reject { |v| v.casecmp?(subject) }
                                             .uniq(&:downcase)
                                             .first(MAX_VARIANTS)

    {
      "subject"          => subject,
      "subject_variants" => variants,
      "preheader" => str(raw["preheader"], 200),
      "intro"     => str(raw["intro"], 600),
      "items"     => items,
      "cta_label" => str(raw["cta_label"], 40).presence || "Open VertoNow",
      "sign_off"  => str(raw["sign_off"], 200),
      "source"    => "claude"
    }
  end

  def str(value, limit)
    return "" unless value.is_a?(String)

    value.strip.truncate(limit)
  end
end
