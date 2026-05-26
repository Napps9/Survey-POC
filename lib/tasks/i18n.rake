require "yaml"

namespace :i18n do
  desc "Fill in missing translations in config/locales/<code>.yml from en.yml via Claude. " \
       "Merges: existing translations are kept, only missing keys are translated. " \
       "Usage: bin/rails i18n:translate          (all languages, missing keys only) " \
       "       bin/rails i18n:translate[es,fr]   (only these) " \
       "       FORCE=1 bin/rails i18n:translate   (re-translate every key)"
  task :translate, [ :only ] => :environment do |_t, args|
    require "anthropic"

    source = YAML.load_file(Rails.root.join("config/locales/en.yml")).fetch("en")
    flat   = flatten_strings(source)

    only  = (args[:only] || ENV["ONLY"]).to_s.split(/[,\s]+/).reject(&:blank?)
    force = ENV["FORCE"].present?

    targets = SupportedLocales.codes - [ "en" ]
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
      print "translating -> #{code} (#{loc&.english_name}) — #{todo.size} key(s)… "

      begin
        response = client.messages.create(
          model: "claude-sonnet-4-6",
          max_tokens: 16384,
          tools: [ {
            name: "submit_translations",
            description: "Submit the translated UI strings as a JSON object keyed by the dotted keys provided.",
            input_schema: {
              type: "object",
              properties: {
                translations: {
                  type: "object",
                  description: "Map of dotted key (exactly as given) to its translation in the target language.",
                  additionalProperties: { type: "string" }
                }
              },
              required: [ "translations" ]
            }
          } ],
          tool_choice: { type: "tool", name: "submit_translations" },
          system: <<~SYS,
            You translate UI strings for a survey app. Use the submit_translations
            tool to return a translations object mapping each given dotted key to
            its translation in the target language. Rules:
            - Translate values only; keep keys exactly as given.
            - Preserve interpolation placeholders like %{name} verbatim.
            - Preserve any HTML tags and their attributes exactly; translate only
              the human-readable text between tags. Leave product/brand names
              (e.g. "Verto", "Playverto") untranslated.
            - Keep it natural and concise for UI use.
          SYS
          messages: [ {
            role: "user",
            content: "Target language: #{loc&.english_name} (#{loc&.native_name}).\n" \
                     "Translate these strings:\n\n" \
                     "#{JSON.pretty_generate(todo)}"
          } ]
        )

        block = Array(response.content).find do |b|
          (b.respond_to?(:type) ? b.type : b["type"]).to_s == "tool_use"
        end
        raise "No tool_use block in response" unless block
        input      = block.respond_to?(:input) ? block.input : block["input"]
        input      = input.transform_keys(&:to_s) if input.respond_to?(:transform_keys)
        translated = input["translations"] || {}
        translated = translated.transform_keys(&:to_s) if translated.respond_to?(:transform_keys)
      rescue StandardError => e
        warn "failed: #{e.class}: #{e.message} — skipping #{code}"
        next
      end

      # Merge: keep existing (unless FORCE), add newly translated, fall back to
      # the English source for anything still missing.
      merged = flat.keys.index_with do |k|
        if force
          translated[k].presence || flat[k]
        else
          existing_flat[k].presence || translated[k].presence || flat[k]
        end
      end

      File.write(out_path, { code => unflatten(merged) }.to_yaml(line_width: -1))
      puts "wrote #{out_path.relative_path_from(Rails.root)} (#{existing_flat.size} kept, #{todo.size} new)"
    end
  end
end

# Flatten a nested hash to { "a.b.c" => "value" } (string leaves only).
def flatten_strings(hash, prefix = nil)
  hash.each_with_object({}) do |(k, v), acc|
    key = [ prefix, k ].compact.join(".")
    if v.is_a?(Hash)
      acc.merge!(flatten_strings(v, key))
    else
      acc[key] = v.to_s
    end
  end
end

# Rebuild a nested hash from { "a.b.c" => "value" }.
def unflatten(flat)
  flat.each_with_object({}) do |(dotted, value), root|
    keys = dotted.split(".")
    leaf = keys[0..-2].reduce(root) { |h, k| h[k] ||= {} }
    leaf[keys.last] = value
  end
end
