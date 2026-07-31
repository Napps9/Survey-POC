require "test_helper"

# P2-2. Controller flash copy was hardcoded English; it now lives under the
# `flash` namespace in all 19 locale files.
#
# This checks the properties a human reviewer cannot check exhaustively across
# 19 languages and hundreds of strings, and that a translator — human or model —
# gets wrong in exactly the same ways:
#
#   * a dropped or renamed %{placeholder}, which raises
#     I18n::MissingInterpolationArgument at runtime, in production, in front of
#     whoever triggered the flash;
#   * an EXTRA placeholder the caller never passes, which raises too;
#   * a missing key, which renders the raw dot path to the user;
#   * a pluralized entry left as a bare string, which raises for languages whose
#     plural rules need a mapping.
#
# The repo already had `locale_rules_parity_test.rb` doing this for the rules
# copy; this is the same idea applied to the namespace P2-2 created.
class LocaleFlashParityTest < ActiveSupport::TestCase
  LOCALES = Dir[Rails.root.join("config/locales/*.yml")]
              .map { |f| File.basename(f, ".yml") }.sort.freeze

  # CLDR categories each language actually needs. A translation missing one of
  # these renders nothing for that count.
  REQUIRED_PLURAL_FORMS = {
    "ar" => %w[zero one two few many other],
    "ru" => %w[one few many other],
    "uk" => %w[one few many other],
    "pl" => %w[one few many other],
    "he" => %w[one other],
    "ja" => %w[other], "ko" => %w[other], "vi" => %w[other], "id" => %w[other],
    "zh" => %w[other]
  }.freeze
  DEFAULT_PLURAL_FORMS = %w[one other].freeze

  def flash_tree(locale)
    I18n.backend.send(:translations)[locale.to_sym]&.dig(:flash) || {}
  end

  # Every leaf as { "dot.path" => value }, where value is a String or, for a
  # pluralized entry, a Hash of CLDR category => String.
  def leaves(node, prefix = [], out = {})
    node.each do |key, value|
      path = prefix + [ key.to_s ]
      if value.is_a?(Hash) && value.keys.map(&:to_s).any? { |k| %w[zero one two few many other].include?(k) }
        out[path.join(".")] = value
      elsif value.is_a?(Hash)
        leaves(value, path, out)
      else
        out[path.join(".")] = value
      end
    end
    out
  end

  def placeholders(text)
    text.to_s.scan(/%\{(\w+)\}/).flatten.sort.uniq
  end

  setup do
    I18n.backend.send(:init_translations) unless I18n.backend.initialized?
    @en = leaves(flash_tree("en"))
  end

  # A floor, not an exact count — new copy should be able to land without
  # editing this test. But the coverage assertions below are all set
  # comparisons against @en, so an EMPTY or badly truncated English set would
  # make every one of them pass vacuously. This is what stops that.
  MINIMUM_KEYS = 110

  test "the flash namespace exists and is substantially populated" do
    assert_operator @en.size, :>=, MINIMUM_KEYS,
                    "expected at least #{MINIMUM_KEYS} flash keys in en.yml (P2-2 moved 116 there); " \
                    "found #{@en.size}. Every other test in this file compares against this set, " \
                    "so a truncated en.yml would make them all pass while proving nothing."
  end

  test "every locale has every key" do
    missing = {}
    LOCALES.each do |locale|
      next if locale == "en"

      have = leaves(flash_tree(locale)).keys
      gap  = @en.keys - have
      missing[locale] = gap if gap.any?
    end
    assert_empty missing,
                 "locales missing flash keys (a missing key renders the raw dot path): #{missing}"
  end

  test "no locale has a key English does not" do
    # A stray key is dead weight, and usually a sign a translator invented a
    # structure rather than mirroring the source.
    extra = {}
    LOCALES.each do |locale|
      next if locale == "en"

      gap = leaves(flash_tree(locale)).keys - @en.keys
      extra[locale] = gap if gap.any?
    end
    assert_empty extra, "locales with unknown flash keys: #{extra}"
  end

  test "placeholders match English exactly in every locale" do
    problems = []
    LOCALES.each do |locale|
      next if locale == "en"

      leaves(flash_tree(locale)).each do |key, value|
        expected = @en[key]
        next if expected.nil?

        expected_ph = expected.is_a?(Hash) ? placeholders(expected.values.join(" ")) : placeholders(expected)
        actual_ph   = value.is_a?(Hash) ? placeholders(value.values.join(" ")) : placeholders(value)

        next if expected_ph.sort == actual_ph.sort

        problems << "#{locale}/#{key}: expected #{expected_ph.inspect}, got #{actual_ph.inspect}"
      end
    end
    assert_empty problems,
                 "placeholder mismatches raise I18n::MissingInterpolationArgument at runtime:\n" +
                 problems.join("\n")
  end

  test "pluralized entries carry the categories their language needs" do
    plural_keys = @en.select { |_k, v| v.is_a?(Hash) }.keys
    skip "no pluralized flash entries" if plural_keys.empty?

    problems = []
    LOCALES.each do |locale|
      required = REQUIRED_PLURAL_FORMS.fetch(locale, DEFAULT_PLURAL_FORMS)
      tree     = leaves(flash_tree(locale))

      plural_keys.each do |key|
        value = tree[key]
        next if value.nil?

        unless value.is_a?(Hash)
          problems << "#{locale}/#{key}: bare string where plural categories are required"
          next
        end

        gap = required - value.keys.map(&:to_s)
        problems << "#{locale}/#{key}: missing #{gap.inspect}" if gap.any?
      end
    end
    assert_empty problems, "plural form problems:\n" + problems.join("\n")
  end

  test "every pluralized form still interpolates the count" do
    problems = []
    LOCALES.each do |locale|
      leaves(flash_tree(locale)).each do |key, value|
        next unless value.is_a?(Hash)
        next unless @en[key].is_a?(Hash)
        next unless placeholders(@en[key].values.join(" ")).include?("count")

        value.each do |form, text|
          problems << "#{locale}/#{key}.#{form}: no %{count}" unless text.to_s.include?("%{count}")
        end
      end
    end
    assert_empty problems, problems.join("\n")
  end

  test "no non-English locale left the English text verbatim" do
    # Catches a translator that skipped entries. Short strings are excluded —
    # a proper noun or a one-word label legitimately matches across languages.
    suspicious = []
    LOCALES.each do |locale|
      next if locale == "en"

      leaves(flash_tree(locale)).each do |key, value|
        english = @en[key]
        next unless english.is_a?(String) && value.is_a?(String)
        next if english.length < 25

        suspicious << "#{locale}/#{key}" if english == value
      end
    end
    assert_empty suspicious,
                 "identical to the English source, so probably untranslated: #{suspicious}"
  end

  # Everything above compares locales against English. None of it can see the
  # other half of the contract: that the keys English defines are the keys the
  # code actually asks for. A controller calling a key that was renamed renders
  # the raw dot path to the user, and 19 locale files would agree with each
  # other perfectly the whole time.
  CALL_SITE = /t\(\s*"(flash\.[a-z0-9_.]+)"/
  SOURCE_DIRS = %w[app/controllers app/models app/views app/services app/jobs app/mailers].freeze

  def flash_call_sites
    Dir[*SOURCE_DIRS.map { |d| Rails.root.join(d, "**/*.{rb,erb}").to_s }]
      .flat_map { |f| File.read(f).scan(CALL_SITE).flatten }
      .uniq.sort
  end

  test "every flash key the code asks for exists, and every key defined is asked for" do
    defined_keys = @en.keys.map { |k| "flash.#{k}" }.sort
    called       = flash_call_sites

    assert_operator called.size, :>, 100,
                    "expected to find the flash call sites by regex; found #{called.size}. " \
                    "If keys started being built dynamically this test needs rewriting, not deleting."

    assert_empty called - defined_keys,
                 "called but not defined — these render the raw dot path to the user: #{(called - defined_keys).inspect}"
    assert_empty defined_keys - called,
                 "defined but never called — dead copy carried in all #{LOCALES.size} locale files: " \
                 "#{(defined_keys - called).inspect}"
  end

  # A translator — human or model — that quietly gives up can return Latin
  # transliteration, or the English source lightly reworded. Neither is caught by
  # anything above: the placeholders match, the keys are all present, and the
  # verbatim-English check only fires on an EXACT match. A script assertion is
  # the one cheap test that separates "translated" from "looks translated".
  SCRIPTS = {
    "ar" => /\p{Arabic}/, "he" => /\p{Hebrew}/, "hi" => /\p{Devanagari}/,
    "ja" => /\p{Hiragana}|\p{Katakana}|\p{Han}/, "ko" => /\p{Hangul}/,
    "ru" => /\p{Cyrillic}/, "uk" => /\p{Cyrillic}/
  }.freeze

  test "non-Latin locales are written in their own script" do
    problems = []
    SCRIPTS.each do |locale, script|
      next unless LOCALES.include?(locale)

      leaves(flash_tree(locale)).each do |key, value|
        Array(value.is_a?(Hash) ? value.values : value).each do |text|
          # Placeholders and the product name are Latin by design, and a string
          # that is nothing else has no script to be in.
          bare = text.to_s.gsub(/%\{\w+\}|Playverto|Verto/, "").strip
          next if bare.length < 10 || text.to_s.match?(script)

          problems << "#{locale}/#{key}: no #{locale} script in #{text.to_s.first(60).inspect}"
        end
      end
    end
    assert_empty problems,
                 "these read as transliteration or untranslated source:\n" + problems.join("\n")
  end

  test "the product name is never translated" do
    # "Verto" is what this product calls a survey and "Playverto" is the brand;
    # both stay as-is in every language, including non-Latin scripts.
    problems = []
    LOCALES.each do |locale|
      next if locale == "en"

      tree = leaves(flash_tree(locale))
      @en.each do |key, english|
        next unless english.is_a?(String) && english.include?("Verto")

        value = tree[key]
        next unless value.is_a?(String)

        problems << "#{locale}/#{key}: lost the product name" unless value.include?("Verto")
      end
    end
    assert_empty problems, problems.join("\n")
  end
end
