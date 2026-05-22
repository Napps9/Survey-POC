# Reads config/supported_locales.yml and exposes the language registry to the
# rest of the app. Single source of truth for every language the product runs in
# (platform UI + Verto content). See the YAML for field docs.
module SupportedLocales
  Locale = Struct.new(:code, :english_name, :native_name, :flag, :dir, keyword_init: true) do
    def rtl? = dir.to_s == "rtl"
    def ltr? = !rtl?
  end

  DEFAULT = "en".freeze

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
  end
end
