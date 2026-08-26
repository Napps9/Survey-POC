require "yaml"

namespace :i18n do
  desc "Fill in missing translations in config/locales/<code>.yml from en.yml via Claude. " \
       "Merges: existing translations are kept, only missing keys are translated. " \
       "Usage: bin/rails i18n:translate          (all languages, missing keys only) " \
       "       bin/rails i18n:translate[es,fr]   (only these) " \
       "       FORCE=1 bin/rails i18n:translate   (re-translate every key)"
  # Batched (~150 keys/call) rather than one giant request, and a translated
  # key is only ever written if the model actually returned it — both fix the
  # same bug: a first run on a brand-new locale could ask for 1000+ keys in
  # one call, the model's response got cut off well before covering them all
  # (max_tokens: 16384 output, not input), and the old code silently filled
  # every key the response DIDN'T cover with the raw English source string as
  # though it were a translation. That written English then looked
  # "translated" (present?) to the next run's own todo filter, so those keys
  # were never retried — a truncated first run permanently pinned however
  # many hundred keys it didn't reach to English. Skipping the fallback write
  # entirely lets a key stay genuinely missing (Rails' own i18n fallback
  # already renders it in English at runtime — config.i18n.fallbacks = true)
  # until a later run actually translates it.
  BATCH_SIZE = 150

  task :translate, [ :only ] => :environment do |_t, args|
    require "anthropic"

    source = YAML.load_file(Rails.root.join("config/locales/en.yml")).fetch("en")
    flat   = flatten_strings(source)

    only  = (args[:only] || ENV["ONLY"]).to_s.split(/[,\s]+/).reject(&:blank?)
    force = ENV["FORCE"].present?

    # English variants are excluded, not merely defaulted past. en-US differs
    # from en by SPELLING, and "translate these strings into English (US)" is
    # not a job a translator can do sensibly — it invites paraphrase where the
    # only wanted change is colour→color. `i18n:en_us` below is its maintenance
    # path, and being a transform it cannot drift structurally.
    targets = SupportedLocales.codes.reject { |c| SupportedLocales.english?(c) }
    targets &= only if only.any?

    client = Anthropic::Client.new(api_key: ENV.fetch("ANTHROPIC_API_KEY"))

    targets.each do |code|
      out_path      = Rails.root.join("config/locales/#{code}.yml")
      existing      = out_path.exist? ? (YAML.load_file(out_path)[code] || {}) : {}
      existing_flat = flatten_strings(existing)

      # Only translate keys that don't already have a translation (unless FORCE).
      todo = force ? flat : flat.reject { |k, _| existing_flat[k].present? }
      if todo.empty?
        puts "skip #{code} (up to date)"
        next
      end

      loc = SupportedLocales.find(code)
      batches = todo.each_slice(BATCH_SIZE).map(&:to_h)
      puts "translating -> #{code} (#{loc&.english_name}) — #{todo.size} key(s) in #{batches.size} batch(es)"

      translated = {}
      batches.each_with_index do |batch, i|
        print "  batch #{i + 1}/#{batches.size} (#{batch.size} keys)… "
        translated.merge!(translate_batch(client, loc, batch))
        puts "ok"
      rescue StandardError => e
        warn "failed: #{e.class}: #{e.message} — keeping what this locale already has for this batch"
      end

      if translated.empty?
        puts "skip #{code} (no batch returned anything usable)"
        next
      end

      # Merge: keep existing (unless FORCE), add newly translated. A key with
      # NEITHER — the model didn't return it and there was no prior
      # translation — is simply left out of the file, not backfilled with
      # English (see BATCH_SIZE comment above for why that was the bug).
      merged = (force ? flat.keys : (existing_flat.keys | translated.keys)).index_with do |k|
        force ? (translated[k].presence || existing_flat[k].presence) : (existing_flat[k].presence || translated[k].presence)
      end.compact

      File.write(out_path, { code => unflatten(merged) }.to_yaml(line_width: -1))
      puts "wrote #{out_path.relative_path_from(Rails.root)} (#{existing_flat.size} kept, #{translated.size} new/updated, #{todo.size - translated.size} still missing)"
    end
  end

  desc "Regenerate config/locales/en-US.yml from en.yml by respelling. " \
       "No API key needed — the two English variants differ in a closed set of " \
       "words, not in meaning. DIFF=1 checks without writing."
  # A word list rather than a regex, and that is the whole design: the near
  # misses are the danger. "analysis" is identical in both variants, and so are
  # "promise", "otherwise", "audience", "sequence", "confidence" and
  # "preference" — every one of which appears in en.yml, and every one of which
  # a blind /is([ae])/ rule would mangle.
  #
  # Generating also makes the KEY STRUCTURE identical by construction, which is
  # what LocaleStructureParityTest, LocaleRulesParityTest and
  # LocaleFlashParityTest each separately require of it.
  task en_us: :environment do
    lines = File.readlines(Rails.root.join("config/locales/en.yml"), encoding: "UTF-8")
    root  = lines.index { |l| l.start_with?("en:") }
    abort "en.yml no longer opens with an `en:` root key" unless root

    out = lines.map do |line|
      if line.strip.start_with?("#")
        EnglishSpellings.americanise(line)
      else
        # The VALUE side only. A key is an identifier the code looks up —
        # `editor.tab_tokens` is asked for by that name in both variants, and
        # respelling keys here would make every one of those lookups miss.
        m = line.match(/\A(\s*(?:- )?)([\w.\-]+:)?(\s*)(.*)\z/m)
        m ? "#{m[1]}#{m[2]}#{m[3]}#{EnglishSpellings.americanise(m[4])}" : line
      end
    end
    out[root] = "en-US:\n"

    body = EN_US_HEADER + out[root..].join
    path = Rails.root.join("config/locales/en-US.yml")

    if ENV["DIFF"].present?
      current = path.exist? ? File.read(path, encoding: "UTF-8") : ""
      puts(body == current ? "en-US.yml is up to date" : "en-US.yml would change — run without DIFF")
      next
    end

    File.write(path, body, encoding: "UTF-8")
    puts "wrote config/locales/en-US.yml"
  end
end

# One batched translation call: { dotted_key => english_source } in,
# { dotted_key => translated_value } out. Keys the model doesn't return (or
# returns unchanged from the key/source) are simply absent from the result —
# callers must not backfill them with English themselves (see BATCH_SIZE).
def translate_batch(client, loc, batch)
  response = client.messages.create(
    model: "claude-opus-4-7",
    max_tokens: 16384,
    tools: [ {
      name: "submit_translations",
      description: "Submit the translated UI strings as an array of {key, value} pairs.",
      input_schema: {
        type: "object",
        properties: {
          translations: {
            type: "array",
            description: "One entry per input key. 'key' is the dotted key exactly as given; 'value' is the translation of the English source string into the target language.",
            items: {
              type: "object",
              properties: {
                key:   { type: "string" },
                value: { type: "string" }
              },
              required: [ "key", "value" ]
            }
          }
        },
        required: [ "translations" ]
      }
    } ],
    tool_choice: { type: "tool", name: "submit_translations" },
    system: <<~SYS,
      You translate UI strings for a survey app and submit them via the
      submit_translations tool.

      The user gives you an object of { dotted_key: english_source_string }.
      You return a translations ARRAY where each entry has:
        - "key":   the dotted key, exactly as given
        - "value": the translation of the English source string into the
                   target language

      CRITICAL: every key in the input must appear exactly once in your
      output. "value" must be the translation. Never repeat the key as the
      value, and never repeat the English source verbatim unless it is a
      brand name ("Verto", "Playverto") or made up of only
      punctuation/numbers/whitespace.

      Worked example, target French:
        input:  { "card.yes": "Yes", "auth.email": "Email address" }
        output translations:
          [
            { "key": "card.yes",   "value": "Oui" },
            { "key": "auth.email", "value": "Adresse e-mail" }
          ]

      Other rules:
      - Preserve interpolation placeholders like %{name} verbatim.
      - Preserve HTML tags and their attributes exactly; translate only
        the human-readable text between tags.
      - Leave brand names ("Verto", "Playverto") untranslated.
      - Keep it natural and concise for UI use.
    SYS
    messages: [ {
      role: "user",
      content: "Target language: #{loc&.english_name} (#{loc&.native_name}).\n" \
               "Translate the English source values below into " \
               "#{loc&.english_name}. Return the SAME dotted keys with " \
               "TRANSLATED values — never copy the key into the value.\n\n" \
               "#{JSON.pretty_generate(batch)}"
    } ]
  )

  block = Array(response.content).find do |b|
    (b.respond_to?(:type) ? b.type : b["type"]).to_s == "tool_use"
  end
  raise "No tool_use block in response" unless block
  input = block.respond_to?(:input) ? block.input : block["input"]
  input = JSON.parse(input) if input.is_a?(String)
  input = input.transform_keys(&:to_s) if input.respond_to?(:transform_keys)
  pairs = input["translations"] || []
  pairs = JSON.parse(pairs) if pairs.is_a?(String)

  pairs.each_with_object({}) do |entry, acc|
    entry = entry.transform_keys(&:to_s) if entry.respond_to?(:transform_keys)
    k = entry["key"].to_s
    v = entry["value"].to_s
    # Sanity: a value equal to its key is a model mistake. Drop it so the
    # caller treats it as not-yet-translated rather than writing junk.
    acc[k] = v unless k.empty? || v == k
  end
end

# Flatten a nested hash to { "a.b.c" => "value" } (string leaves only). Array
# leaves are flattened too — each element becomes "a.b.c[0]", "a.b.c[1]", … so
# array-typed translations (e.g. example lists) round-trip back to arrays
# instead of being stringified.
def flatten_strings(hash, prefix = nil)
  hash.each_with_object({}) do |(k, v), acc|
    key = [ prefix, k ].compact.join(".")
    case v
    when Hash
      acc.merge!(flatten_strings(v, key))
    when Array
      v.each_with_index { |item, i| acc["#{key}[#{i}]"] = item.to_s }
    else
      acc[key] = v.to_s
    end
  end
end

# Rebuild a nested hash from { "a.b.c" => "value" }. Keys ending in "[N]" are
# rebuilt as arrays (companion to flatten_strings's array handling).
ARRAY_KEY = /\A(.+)\[(\d+)\]\z/

def unflatten(flat)
  flat.each_with_object({}) do |(dotted, value), root|
    if (m = dotted.match(ARRAY_KEY))
      base, idx = m[1], m[2].to_i
      keys = base.split(".")
      leaf = keys[0..-2].reduce(root) { |h, k| h[k] ||= {} }
      leaf[keys.last] ||= []
      leaf[keys.last][idx] = value
    else
      keys = dotted.split(".")
      leaf = keys[0..-2].reduce(root) { |h, k| h[k] ||= {} }
      leaf[keys.last] = value
    end
  end
end

# ── US English ──────────────────────────────────────────────────────────────
# The word list itself is EnglishSpellings (app/lib), not here: it is product
# knowledge about the copy, it is what LocaleEnUsTest checks, and a rake file
# cannot be tested.

EN_US_HEADER = <<~HEAD
  # US English — GENERATED from en.yml by `bin/rails i18n:en_us`. Do not edit by
  # hand; regenerate.
  #
  # Two English variants exist because the PDF import's optimiser was quietly
  # rewriting a creator's US spellings into UK ones. It had no instruction about
  # spelling at all — every generator's language instruction was skipped for the
  # default locale — so the model simply inherited the dialect of the prompts,
  # which are written in British English throughout. See PromptLanguage.
  #
  # A transform, not a translation: the structure has to mirror en.yml exactly
  # or the three locale parity tests fail, which is what they are for.
HEAD
