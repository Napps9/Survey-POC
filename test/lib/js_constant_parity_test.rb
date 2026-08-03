require "test_helper"

# Several card-type lists exist twice: once in Ruby, once in a JS module the
# editor and player import. Today they are kept in step by comments that say
# "keep in lock-step" — which is not a mechanism.
#
# That is not hypothetical. `consent_gate` was added to Survey::PAGED_TYPES on
# the server and the JS side kept saying `type === "scenario"`, so the editor
# stopped emitting `pages` for a consent gate: every autosave posted the card
# with no pages, the sanitiser rewrote them to [], and the gate went on
# blocking respondents while showing a blank screen and recording no consent
# snapshot — the compliance artefact the feature exists for. The whole feature
# had passing tests, because none of them made a round trip through the editor.
#
# Parsing JS with a regex is crude, but the alternative is a JS test runner the
# repo doesn't have, and the assertions below fail loudly if the shape of the
# file changes rather than silently passing.
class JsConstantParityTest < ActiveSupport::TestCase
  def js(path)
    File.read(Rails.root.join("app/javascript", path))
  end

  # Pulls `export const NAME = [ "a", "b" ]` out of a module.
  def js_array(path, name)
    source = js(path)
    match  = source[/export const #{Regexp.escape(name)}\s*=\s*\[(.*?)\]/m]
    assert match, "#{path} no longer exports a `#{name}` array — this test can " \
                  "no longer see the constant it is meant to be guarding."
    match[/\[(.*?)\]/m, 1].scan(/"([^"]+)"/).flatten
  end

  test "lib/paged_types.js matches Survey::PAGED_TYPES" do
    assert_equal Survey::PAGED_TYPES.sort, js_array("lib/paged_types.js", "PAGED_TYPES").sort,
                 "the editor decides whether to serialize a card's `pages` from this list. " \
                 "A type the server treats as paged but the JS does not will have its pages " \
                 "silently dropped on the next autosave."
  end

  test "lib/routable_types.js matches LogicGraph::ROUTABLE" do
    assert_equal LogicGraph::ROUTABLE.map(&:to_s).sort,
                 js_array("lib/routable_types.js", "ROUTABLE_TYPES").sort,
                 "a type routable on the server but not in the editor gets no routing UI; " \
                 "the reverse offers routing the compiler will discard."
  end

  test "lib/question_types.js matches CardTypes::NON_QUESTION_TYPES" do
    assert_equal CardTypes::NON_QUESTION_TYPES.sort,
                 js_array("lib/question_types.js", "NON_QUESTION_TYPES").sort,
                 "a type the server treats as a non-question but the JS does not gets scored, " \
                 "counted and rendered as if it asked something."
  end

  # This list was hand-copied into four JS files and one of them went stale —
  # results_compare kept the two-element version from before consent_gate, so
  # the compare view built an empty expandable block for one. There is one copy
  # now, and this asserts nobody re-types it.
  test "the non-question list is defined once" do
    definitions = Dir[Rails.root.join("app/javascript/**/*.js")].select do |path|
      File.read(path).match?(/(?:const|let|var)\s+(?:NON_QUESTION_TYPES|SKIP_TYPES)\s*=\s*(?:new Set\()?\[/)
    end.map { |path| path.sub("#{Rails.root}/app/javascript/", "") }

    assert_equal [ "lib/question_types.js" ], definitions,
                 "import NON_QUESTION_TYPES from lib/question_types instead of re-typing it"
  end

  # Every type a creator can pick must have placeholder options — including the
  # ones that deliberately have none, so an omission stays distinguishable from
  # a decision. `prioritise` and `nps` were missing from the add-question copy,
  # so picking Prioritise there produced a card with no options at all.
  test "every pickable type has default options" do
    source = js("lib/default_options.js")
    table  = source[/export const DEFAULT_OPTIONS = \{(.*?)\n\}/m]
    assert table, "DEFAULT_OPTIONS not found in lib/default_options.js"

    missing = CardTypes.pickable.map(&:first).reject { |type| table.match?(/^\s+#{Regexp.escape(type)}:/) }
    assert_empty missing,
                 "these pickable types have no entry, so a card created as one arrives empty: " \
                 "#{missing.inspect}"
  end

  test "the default-options table is defined once" do
    definitions = Dir[Rails.root.join("app/javascript/**/*.js")].select do |path|
      File.read(path).match?(/(?:export\s+)?(?:const|let|var)\s+DEFAULT_OPTIONS\s*=\s*\{/)
    end.map { |path| path.sub("#{Rails.root}/app/javascript/", "") }

    assert_equal [ "lib/default_options.js" ], definitions
  end

  # Bounds, not lists — same mirroring problem, and these had no JS side at all,
  # so the editor let a creator write a seventh page and the sanitiser dropped
  # it on the next save without a word.
  def js_number(path, name)
    source = js(path)
    match  = source[/export const #{Regexp.escape(name)}\s*=\s*(\d+)/, 1]
    assert match, "#{path} no longer exports a numeric `#{name}`"
    match.to_i
  end

  test "lib/page_limits.js matches the Survey page bounds" do
    assert_equal Survey::MAX_SCENARIO_PAGES, js_number("lib/page_limits.js", "MAX_PAGES"),
                 "the editor refuses to add a page past this; if it is higher than the " \
                 "server's cap the extra pages are silently discarded on save."
    assert_equal Survey::MAX_SCENARIO_PAGE_LENGTH, js_number("lib/page_limits.js", "MAX_PAGE_LENGTH")
  end

  # The advisory scoring thresholds must stay STRICTER than the hard caps, so a
  # creator is nudged well before anything is actually thrown away.
  test "the Rules of the Game warn before the hard limits bite" do
    rules = js("lib/verto_rules.js")
    max_pages  = rules[/PAGE_RULES\s*=\s*\{[^}]*max:\s*(\d+)/, 1].to_i
    max_length = rules[/PAGE_LENGTH_LIMIT\s*=\s*(\d+)/, 1].to_i

    assert_operator max_pages, :>, 0, "expected to find PAGE_RULES.max in verto_rules.js"
    assert_operator max_pages, :<=, Survey::MAX_SCENARIO_PAGES
    assert_operator max_length, :>, 0, "expected to find PAGE_LENGTH_LIMIT in verto_rules.js"
    assert_operator max_length, :<=, Survey::MAX_SCENARIO_PAGE_LENGTH
  end

  # The list is only worth asserting against if it is non-trivial — an empty or
  # unparsed array would make both tests above pass by comparing nothing.
  test "the parsed JS constants are non-empty" do
    assert_operator js_array("lib/paged_types.js", "PAGED_TYPES").size, :>=, 2
    assert_operator js_array("lib/routable_types.js", "ROUTABLE_TYPES").size, :>=, 5
  end

  # Option-row markup existed three times client-side (type panel rebuilds,
  # card_editor's "Add option", scenario's answer page) and one copy drifted:
  # "＋ Add option" built a tile-less row that sat visibly mis-sized between
  # the server-rendered rows until the next reload. One template module now.
  test "the option-row markup is defined once" do
    %w[choice-list-item\ pick-item choice-card].each do |marker|
      definitions = Dir[Rails.root.join("app/javascript/**/*.js")].select do |path|
        File.read(path).include?(%(class="#{marker}"))
      end.map { |path| path.sub("#{Rails.root}/app/javascript/", "") }

      assert_equal [ "lib/choice_templates.js" ], definitions,
                   "build option rows via lib/choice_templates instead of re-typing the " \
                   "markup — a drifted copy renders mis-sized rows until the next reload"
    end
  end

  # The palette maths lives twice (live preview vs server render); the roles
  # drifting means a colour a creator can pick that one side silently ignores.
  test "lib/brand_palette.js roles and defaults match BrandPalette" do
    assert_equal BrandPalette::ROLES, js_array("lib/brand_palette.js", "ROLES"),
                 "a role missing from the JS side never live-previews; missing from " \
                 "Ruby it never renders for respondents"

    js_default = js("lib/brand_palette.js")[/export const DEFAULT = \{(.*?)\}/m, 1]
                   .scan(/(\w+):\s*"([^"]+)"/).to_h
    assert_equal BrandPalette::DEFAULT, js_default,
                 "differing defaults make default? disagree across the mirror, so the " \
                 "same palette brands the player but not the editor (or vice versa)"
  end

  # The specific hole the drift went through: the editor's type panel builds a
  # card's right-hand component from a lookup table, falling back to an empty
  # string. A type missing from that table silently blanks the card when a
  # creator picks it, which is how consent_gate behaved.
  #
  # Scoped to EVERY pickable type, not just the paged ones. The first version of
  # this test checked PAGED_TYPES only and passed while `token_checkpoint` — the
  # one other type with the same gap — was still missing. A guard written from a
  # single bug tends to be shaped like that bug; the rule is "anything a creator
  # can pick must render as something".
  test "every pickable card type has a component builder in the type panel" do
    source = js("controllers/type_panel_controller.js")
    table  = source[/const COMPONENTS = \{(.*?)\n\}/m]
    assert table, "COMPONENTS table not found in type_panel_controller.js"

    pickable = CardTypes.pickable.map(&:first)
    assert_operator pickable.size, :>=, 10, "expected the pickable list to be substantial"

    missing = pickable.reject { |type| table.match?(/^\s+#{Regexp.escape(type)}:/) }
    assert_empty missing,
                 "these types fall through to COMPONENTS' `() => \"\"` default, so picking " \
                 "them in the Answer Type panel blanks the card: #{missing.inspect}. " \
                 "A type that deliberately renders nothing still needs an explicit entry " \
                 "(see welcome_card), so an omission stays distinguishable from a decision."
  end

  # The original defect, stated directly: `type === "scenario"` where the rule is
  # "is this a paged type".
  #
  # Scanned across every editor JS file rather than the two that were fixed —
  # the first version listed two paths by hand and missed lib/verto_rules.js,
  # which still had the literal. A ban that only covers the files you already
  # edited bans nothing.
  test "no editor JS gates paged behaviour on the literal type name" do
    offenders = Dir[Rails.root.join("app/javascript/**/*.js")].filter_map do |path|
      rel = path.sub("#{Rails.root}/app/javascript/", "")
      # Comments stripped first: lib/paged_types.js documents the banned pattern
      # by quoting it, and a guard that flags its own explanation is a guard
      # people delete.
      code = File.read(path).gsub(%r{//.*$}, "")
      rel if code.match?(/type\s*===\s*"scenario"/)
    end
    assert_empty offenders,
                 "#{offenders.inspect} gate behaviour on the literal type `scenario`. " \
                 "Use isPaged() from lib/paged_types so a new paged type is picked up — " \
                 "this is what let a consent gate lose its pages on every save."
  end
end
