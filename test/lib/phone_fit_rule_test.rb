require "test_helper"

# The editor's phone-fit tip, and the two numbers it rests on.
#
# COUNT_RULES lets an image grid have up to ten answers, and a creator building
# on a desktop sees all ten drawn as tiles. The phone player cannot show that:
# it works to a height budget and buys the imagery back only while the answer
# still fits (player_controller#_fitCard), so past a certain count the card the
# respondent gets is not the card the creator was shown. verto_rules'
# phoneFitCheck is what says so, before the Verto is published rather than
# after someone complains.
#
# The thresholds were measured — a two-column grid at the 16px option label,
# walked across a 280px Fold, a 375 SE, a 393 iPhone and a 430 Max. Seven is
# where the hero image stops fitting on all four; nine is where the options
# themselves begin to scroll with the hero already gone. They are asserted here
# because a plausible-looking edit to either (or a copy-paste that swaps them)
# changes what creators are told with nothing else noticing.
#
# Regex against the JS for the same reason js_constant_parity_test does it:
# there is no JS test runner in this repo, and a loud failure when the file's
# shape changes beats no coverage at all.
class PhoneFitRuleTest < ActiveSupport::TestCase
  RULES = Rails.root.join("app/javascript/lib/verto_rules.js").freeze
  LOCALES = Rails.root.glob("config/locales/*.yml").freeze

  def source
    @source ||= File.read(RULES)
  end

  def constant(name)
    m = source[/const #{Regexp.escape(name)}\s*=\s*(\d+)/, 1]
    assert m, "verto_rules.js no longer defines #{name} — this test can't see what it guards."
    m.to_i
  end

  test "the thresholds are the measured ones, in the right order" do
    hero = constant("PHONE_HERO_LIMIT")
    fit  = constant("PHONE_FIT_LIMIT")

    assert_equal 7, hero, "measured: at seven grid answers a phone drops the card image to fit them"
    assert_equal 9, fit,  "measured: at nine the options scroll even with the image already gone"
    assert_operator hero, :<, fit,
                    "losing the picture has to come BEFORE the options scroll — the other way " \
                    "round tells creators the options are at risk while the card is still fine."
  end

  # The editor stops a grid tile label being typed past this, and the Rules of
  # the Game panel advises the same number — because they ARE the same number.
  # GRID_LABEL_MAX is derived from OPTION_LIMITS rather than written out again,
  # so this asserts the derivation is still in place and not a copy that has
  # drifted. A creator being nagged at 20 and stopped at 25 is the editor
  # disagreeing with itself, which is what the cap existed to end.
  test "the hard cap is the number the rules already advise" do
    assert_match(/GRID_LABEL_MAX\s*=\s*OPTION_LIMITS\.select_one_grid/, source,
                 "GRID_LABEL_MAX should be derived from OPTION_LIMITS, not restated — " \
                 "two copies of a limit is one copy too many.")

    limits = source[/const OPTION_LIMITS\s*=\s*\{(.*?)\}/m, 1]
    assert limits, "OPTION_LIMITS is gone or reshaped past recognition"
    grid = limits.scan(/select_(?:one|many)_grid:\s*(\d+)/).flatten.map(&:to_i)

    assert_equal [ 20, 20 ], grid,
                 "both image-grid types carry the tile-label cap and it is 20: measured at " \
                 "16px, a 393px phone gives the grid column ~172px and ~8.6px a character."
  end

  # A list row spans the answer panel where a tile gets a column of it, so it
  # holds about half as much again — measured at 16px: 32 characters a line on
  # a 393px phone against a tile's 22, and 19 against 15 on a 280px Fold. The
  # two limits are meant to differ, so both are pinned; a well-meaning tidy-up
  # that made them match would be a silent halving of what a list may say.
  test "list labels carry the wider budget" do
    limits = source[/const OPTION_LIMITS\s*=\s*\{(.*?)\}/m, 1]
    lists  = %w[multiple_choice select_many prioritise].to_h do |type|
      [ type, limits[/#{type}:\s*(\d+)/, 1].to_i ]
    end

    assert_equal({ "multiple_choice" => 40, "select_many" => 40, "prioritise" => 40 }, lists,
                 "the list types share one budget and it is 40, wider than the grids' 20")
  end

  # The tightest budget in the table, and the only one shared by two card types
  # that don't look alike: a range slider's five stops and a tap card's response
  # strip. Both print EVERY label at once, side by side, so each gets the width
  # divided by the count — about 70px on a 390px phone at five across. Seventeen
  # is what fits there, and it is exactly the length of "Strongly disagree", the
  # longest label either scale ships.
  #
  # Pinned because raising it silently un-does the slider's one-row layout: the
  # stagger onto two rows was removed on the strength of this number, and a
  # label past it puts the row's height back under the creator's control.
  test "the scale answer labels carry the tightest budget, and it is one number" do
    assert_match(/SCALE_LABEL_MAX\s*=\s*OPTION_LIMITS\.range/, source,
                 "SCALE_LABEL_MAX should be derived from OPTION_LIMITS, not restated — " \
                 "the slider's cap and the tap strip's cap are the same cap.")

    limits = source[/const OPTION_LIMITS\s*=\s*\{(.*?)\}/m, 1]
    assert_equal 17, limits[/\brange:\s*(\d+)/, 1].to_i,
                 "measured: five labels across a 390px phone give each ~70px, which holds 17 " \
                 "characters wrapped inside its own column — and 'Strongly disagree' is 17."

    assert_match(/CAPPED_LABEL_TYPES\s*=\s*\[\s*\.\.\.GRID_LABEL_TYPES,\s*"range"/, source,
                 "range has to be in CAPPED_LABEL_TYPES, not merely counted: an over-long stop " \
                 "changes the height of the whole label row rather than just its own.")
  end

  test "the check counts the Other box, the way the count rule does" do
    body = source[/function phoneFitCheck\(card\)\s*\{(.*?)\n\}/m, 1]

    assert body, "phoneFitCheck is gone or has been reshaped past recognition"
    assert_match(/allowOther/, body,
                 "an image grid's Other box takes a tile like any other answer, and countCheck " \
                 "already counts it. Not counting it here puts the tip one answer late.")
    assert_match(/select_one_grid|select_many_grid/, body,
                 "the tip only applies to the image-grid types — the list types have no tiles to lose")
  end

  # A non-scoring tip. Ten answers is inside the Rules of the Game, and a
  # creator making a desktop-first Verto is not doing anything wrong; marking
  # the card down for it would be the editor contradicting its own rule.
  test "the tip advises rather than scores" do
    body = source[/function phoneFitCheck\(card\)\s*\{(.*?)\n\}/m, 1]

    assert_match(/check\("phone",\s*INFO/, body,
                 "phoneFitCheck should be rated INFO (CARD_PENALTY[INFO] is 0). Anything else " \
                 "deducts points for an option count COUNT_RULES explicitly permits.")
  end

  # verto_rules looks its strings up at runtime through window.I18N, so a key
  # missing from any locale renders to the respondent-facing editor as a raw
  # dotted string. locale_rules_parity_test enforces that the whole block
  # matches en.yml; this names the two keys so a rename can't quietly take the
  # tip's text away in all nineteen at once.
  test "both messages exist in every locale" do
    LOCALES.each do |file|
      locale = File.basename(file, ".yml")
      rules  = YAML.load_file(file).dig(locale, "js", "editor", "rules") || {}

      %w[phone_hero phone_scroll].each do |key|
        assert rules[key].present?, "#{locale}.yml is missing js.editor.rules.#{key}"
        assert_includes rules[key], "%{n}", "#{locale}.yml's #{key} should report the count"
      end
    end
  end
end
