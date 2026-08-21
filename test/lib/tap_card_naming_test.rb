require "test_helper"

# The card type is `tap_card` in the code and was "Swipe" in every string a
# person could read — badge, eyebrow, panel label, type label, picker name and
# the type-swap advice. Respondents were told to swipe a card they tap.
#
# The rename is easy to half-do: the strings live in TWO places (the locale
# files win, config/card_types.yml is only the English fallback — see
# CardTypes.badge), across 25 files, plus prose in the type-swap notes. This
# pins the whole surface rather than any one key.
class TapCardNamingTest < ActiveSupport::TestCase
  LOCALES = Dir[Rails.root.join("config/locales/*.yml")].freeze

  # The answer VALUES are still yes/unsure/no and their keys are historic
  # (`swipe_yes` etc.) — renaming those would migrate stored response data for
  # a cosmetic gain. `swipe_hint` already reads "Drag or tap to answer".
  KEY_ALLOWLIST = /^\s*swipe_(no|yes|unsure|hint):/

  # Deliberately narrow. A first attempt swept every locale for any word
  # meaning "slide" and drowned in false positives: `deslizar`/`glisser` are
  # what the RANGE slider is called in Spanish and French and are correct
  # there, and "wisch" matches inside the German for a token checkpoint
  # ("ZWISCHENSTAND"). So match only the unambiguous swipe words, and only
  # where they are not a historic key name.
  SWIPE_WORDS = /swipe|スワイプ|스와이프|свайп|Wisch-Gefühl|Wisch-Mechanik/i

  test "no respondent-facing string calls a tap card a swipe" do
    offenders = LOCALES.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, i|
        next if line =~ KEY_ALLOWLIST
        next unless line.match?(SWIPE_WORDS)
        "#{File.basename(path)}:#{i + 1} #{line.strip}"
      end
    end

    assert_empty offenders,
                 "these read as 'swipe' to a user. The type is called Tap now — the copy has " \
                 "to agree, in every language, or a respondent is told to swipe a card that " \
                 "asks them to tap:\n  #{offenders.join("\n  ")}"
  end

  # The four keys that name the type itself, in every language. A half-done
  # translation shows up as the English word surviving in a non-English file,
  # which is the specific failure this catches.
  test "no locale left the English word in a tap-card key" do
    keys = %w[card.eyebrow.tap_card card.badge.tap_card
              card.panel_label.tap_card card.type_label.tap_card]

    LOCALES.each do |path|
      code = File.basename(path, ".yml")
      keys.each do |key|
        value = I18n.t(key, locale: code, default: "")
        next if value.blank?
        refute_match(/swipe/i, value, "#{code}: #{key} is #{value.inspect}")
      end
    end
  end

  test "the YAML fallbacks agree with the locale" do
    meta = CardTypes.meta("tap_card")

    assert_equal "TAP", meta["badge"]
    assert_equal "TAP TO RESPOND", meta["panel_label"]
    assert_equal "Tap to respond", meta["eyebrow"]
    # picker_name/picker_desc are NOT localised — read straight from the YAML
    # by _add_question_modal — so the YAML is the only place they can be right.
    assert_equal "Tap Cards", meta["picker_name"]
    refute_match(/swipe/i, meta["picker_desc"])
    refute_match(/swipe/i, meta["explainer"])
  end

  test "the prioritise eyebrow lost its instruction preamble" do
    # "Click and drag to arrange in order of priority" was doing two jobs and
    # the drag part is already obvious from the rows.
    assert_equal "Arrange in order of priority", CardTypes.meta("prioritise")["eyebrow"]
    assert_equal "Arrange in order of priority", I18n.t("card.eyebrow.prioritise", locale: :en)
  end
end
