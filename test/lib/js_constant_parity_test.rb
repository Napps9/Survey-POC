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

  # The list is only worth asserting against if it is non-trivial — an empty or
  # unparsed array would make both tests above pass by comparing nothing.
  test "the parsed JS constants are non-empty" do
    assert_operator js_array("lib/paged_types.js", "PAGED_TYPES").size, :>=, 2
    assert_operator js_array("lib/routable_types.js", "ROUTABLE_TYPES").size, :>=, 5
  end

  # The specific hole the drift went through: the editor's type panel builds a
  # card's right-hand component from a lookup table, falling back to an empty
  # string. A paged type missing from that table silently blanks the card when
  # a creator picks it, which is how consent_gate behaved.
  test "every paged type has a component builder in the type panel" do
    source = js("controllers/type_panel_controller.js")
    table  = source[/const COMPONENTS = \{(.*?)\n\}/m]
    assert table, "COMPONENTS table not found in type_panel_controller.js"

    missing = Survey::PAGED_TYPES.reject { |type| table.match?(/^\s+#{Regexp.escape(type)}:/) }
    assert_empty missing,
                 "these paged types fall through to COMPONENTS' `() => \"\"` default, so " \
                 "picking them in the Answer Type panel blanks the card: #{missing.inspect}"
  end

  test "the JS page gate is not keyed on a single literal type" do
    # The original defect, stated directly: `type === "scenario"` where the rule
    # is "is this a paged type". Both files now import isPaged instead.
    %w[controllers/survey_editor_controller.js controllers/type_panel_controller.js].each do |path|
      refute_match(/type\s*===\s*"scenario"/, js(path),
                   "#{path} still gates behaviour on the literal type `scenario`. " \
                   "Use isPaged() from lib/paged_types so a new paged type is picked up.")
    end
  end
end
