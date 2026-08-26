# Reads config/supported_locales.yml and exposes the language registry to the
# rest of the app. Single source of truth for every language the product runs in
# (platform UI + Verto content). See the YAML for field docs.
module SupportedLocales
  Locale = Struct.new(:code, :english_name, :native_name, :flag, :dir, keyword_init: true) do
    def rtl? = dir.to_s == "rtl"
    def ltr? = !rtl?
  end

  DEFAULT = "en".freeze

  # The English variants. They share a language and differ only in spelling, so
  # code that means "is this Verto in English" has to ask about the set rather
  # than compare against DEFAULT — which is what every generator's language
  # instruction used to do, and why an en-US Verto would otherwise sail past the
  # guard and be told "…in English (US). Do not use English."
  ENGLISH = %w[en en-US].freeze

  class << self
    # All locales in registry order.
    def all
      @all ||= load_file.map { |h| Locale.new(**h.symbolize_keys.slice(:code, :english_name, :native_name, :flag, :dir)) }
    end

    # ["en", "es", ...] as strings, in registry order.
    def codes
      @codes ||= all.map(&:code)
    end

    # Symbols for Rails I18n.available_locales.
    def symbols
      @symbols ||= codes.map(&:to_sym)
    end

    # Locales whose platform UI is translated enough to show in the picker:
    # file exists, parses, and covers ≥ COVERAGE_THRESHOLD of en.yml's keys.
    # English is always included. Anything still missing falls back to en.yml
    # via Rails I18n at render time, so a feature that adds a couple of new
    # keys without translating them leaves the locale visible (with a few
    # English words) instead of removing it from the switcher entirely.
    # Verto content pickers should keep using `all`.
    COVERAGE_THRESHOLD = 0.80

    def ui_ready
      @ui_ready ||= all.select { |loc| ui_ready_codes.include?(loc.code) }
    end

    def find(code)
      index[code.to_s]
    end

    def supported?(code)
      index.key?(code.to_s)
    end

    # Coerce arbitrary input to a known code, falling back to DEFAULT.
    def coerce(code)
      supported?(code) ? code.to_s : DEFAULT
    end

    def english?(code)
      ENGLISH.include?(code.to_s)
    end

    # Resolve one Accept-Language tag ("en-US", "en-gb", "pt-BR") to a supported
    # code, or nil.
    #
    # The full tag first, case-insensitively, because that is the only way a US
    # browser can reach `en-US` at all — the header carries a region subtag and
    # the old resolver threw it away before looking anything up. Then the bare
    # language subtag, which is what every other entry in the registry is keyed
    # by and what makes "pt-BR" still find Portuguese.
    def coerce_tag(tag)
      raw = tag.to_s.strip
      return nil if raw.blank?

      exact = codes.find { |c| c.casecmp?(raw) }
      return exact if exact

      base = raw.split("-").first.to_s.downcase
      base.presence && supported?(base) ? base : nil
    end

    def flag(code)        = find(code)&.flag
    def native_name(code) = find(code)&.native_name
    def english_name(code) = find(code)&.english_name
    def dir(code)         = find(code)&.dir || "ltr"
    def rtl?(code)        = find(code)&.rtl? || false

    # Keep only supported codes, de-duplicated, preserving caller order.
    def sanitize_list(codes_in, fallback: [ DEFAULT ])
      list = Array(codes_in).map(&:to_s).select { |c| supported?(c) }.uniq
      list.presence || fallback
    end

    private

    def index
      @index ||= all.index_by(&:code)
    end

    def load_file
      YAML.load_file(Rails.root.join("config/supported_locales.yml")).fetch("locales")
    end

    def ui_ready_codes
      @ui_ready_codes ||= begin
        en_keys = locale_keys(DEFAULT) || []
        min_coverage = (en_keys.size * COVERAGE_THRESHOLD).ceil
        codes.select do |code|
          next true if code == DEFAULT
          keys = locale_keys(code)
          keys && (en_keys & keys).size >= min_coverage
        end.to_set
      end
    end

    def locale_keys(code)
      path = Rails.root.join("config/locales/#{code}.yml")
      return nil unless path.exist?
      data = YAML.load_file(path)
      root = data.is_a?(Hash) ? data[code] : nil
      root.is_a?(Hash) ? flatten_keys(root) : nil
    end

    def flatten_keys(hash, prefix = nil)
      hash.flat_map do |k, v|
        key = [ prefix, k ].compact.join(".")
        v.is_a?(Hash) ? flatten_keys(v, key) : [ key ]
      end
    end
  end
end
