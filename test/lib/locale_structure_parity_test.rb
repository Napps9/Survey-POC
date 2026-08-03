require "test_helper"

# The 19 locale files are documented as mirroring en.yml's structure, but
# nothing enforced it — which is how the `welcome_mailer` and new `js.*`
# namespaces could drift (a review finding). A key missing from one locale
# doesn't raise; it silently falls back to English (or renders a raw dotted
# key from JS), so the only reliable guard is structural.
#
# Scoped to the namespaces the browser depends on — `js` (window.I18N),
# `defaults` (placeholder card content, resolved per Verto locale) and `card`
# (curated into window.I18N by _i18n_js) — because a hole in these is
# user-visible English in a non-English UI, the exact defect this pass
# removed. Widening it to every namespace is desirable but needs the
# backfill done first.
class LocaleStructureParityTest < ActiveSupport::TestCase
  NAMESPACES = %w[js defaults card].freeze

  def locale_files
    Dir[Rails.root.join("config/locales/*.yml")]
  end

  def load_locale(path)
    data = YAML.load_file(path)
    [ data.keys.first, data.values.first ]
  end

  def deep_keys(node, prefix = nil)
    return [ prefix ] unless node.is_a?(Hash)
    node.flat_map { |k, v| deep_keys(v, prefix ? "#{prefix}.#{k}" : k.to_s) }
  end

  test "every locale mirrors en.yml's browser-facing namespaces" do
    en = load_locale(Rails.root.join("config/locales/en.yml").to_s).last
    en_keys = NAMESPACES.index_with { |ns| deep_keys(en[ns], ns).sort }

    problems = []
    locale_files.each do |path|
      code, data = load_locale(path)
      next if code == "en"

      NAMESPACES.each do |ns|
        missing = en_keys[ns] - deep_keys(data[ns], ns)
        extra   = deep_keys(data[ns], ns) - en_keys[ns]
        problems << "#{File.basename(path)}: missing #{missing.take(8).inspect}#{"…" if missing.size > 8}" if missing.any?
        problems << "#{File.basename(path)}: extra #{extra.take(8).inspect}#{"…" if extra.size > 8}" if extra.any?
      end
    end

    assert_empty problems,
                 "locale files out of step with en.yml — a missing key here renders as " \
                 "English (or a raw dotted key) in that language:\n  #{problems.join("\n  ")}"
  end

  # The defaults lists are POSITIONAL content (a range scale's stop 3 must stay
  # stop 3 in every language), so same keys isn't enough — same shape is the
  # contract.
  test "every locale's defaults lists match en.yml's lengths" do
    en = load_locale(Rails.root.join("config/locales/en.yml").to_s).last["defaults"]
    assert en.is_a?(Hash), "en.yml lost its defaults: namespace"

    problems = []
    locale_files.each do |path|
      code, data = load_locale(path)
      next if code == "en"
      d = data["defaults"]
      next unless d.is_a?(Hash) # the key-parity test above reports the hole

      en.each do |type, list|
        theirs = d[type]
        unless theirs.is_a?(Array) && theirs.size == list.size
          problems << "#{File.basename(path)}: defaults.#{type} is #{theirs.class}/#{theirs.respond_to?(:size) ? theirs.size : '-'}, en has #{list.size}"
        end
      end
    end

    assert_empty problems, "positional defaults out of shape:\n  #{problems.join("\n  ")}"
  end
end
