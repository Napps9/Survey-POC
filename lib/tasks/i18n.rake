require "yaml"

namespace :i18n do
  desc "Translate config/locales/en.yml into every other supported language via Claude. " \
       "Usage: bin/rails i18n:translate          (all missing locales) " \
       "       bin/rails i18n:translate[es,fr]   (only these) " \
       "       FORCE=1 bin/rails i18n:translate   (overwrite existing files)"
  task :translate, [ :only ] => :environment do |_t, args|
    require "anthropic"

    source_path = Rails.root.join("config/locales/en.yml")
    source = YAML.load_file(source_path).fetch("en")

    only = (args[:only] || ENV["ONLY"]).to_s.split(/[,\s]+/).reject(&:blank?)
    force = ENV["FORCE"].present?

    targets = SupportedLocales.codes - [ "en" ]
    targets &= only if only.any?

    client = Anthropic::Client.new(api_key: ENV.fetch("ANTHROPIC_API_KEY"))

    targets.each do |code|
      out_path = Rails.root.join("config/locales/#{code}.yml")
      if out_path.exist? && !force
        puts "skip #{code} (exists; FORCE=1 to overwrite)"
        next
      end

      loc = SupportedLocales.find(code)
      print "translating -> #{code} (#{loc&.english_name})… "
      flat = flatten_strings(source)

      response = client.messages.create(
        model: "claude-sonnet-4-6",
        max_tokens: 8192,
        system: <<~SYS,
          You translate UI strings for a survey app. Return ONLY a JSON object
          mapping each given dotted key to its translation in the target
          language. Rules:
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
                   "Translate these strings and return a JSON object of key => translation:\n\n" \
                   "#{JSON.pretty_generate(flat)}"
        } ]
      )

      text = Array(response.content).map { |b| b.respond_to?(:text) ? b.text : b["text"] }.join
      json = text[/\{.*\}/m] or raise "No JSON in response for #{code}"
      translated = JSON.parse(json)

      nested = unflatten(flat.keys.index_with { |k| translated[k] || flat[k] })
      File.write(out_path, { code => nested }.to_yaml(line_width: -1))
      puts "wrote #{out_path.relative_path_from(Rails.root)}"
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
