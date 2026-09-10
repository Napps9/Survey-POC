require "test_helper"

# The vessel geometry exists TWICE: NpsHelper draws it server-side, and
# lib/nps_vessels.js redraws it client-side — when a creator switches a card's
# type to NPS (type-panel) and when they pick a different container
# (survey-editor#setNpsShape), both without a round-trip. Both files say "keep
# the two in sync" and nothing checked that they were — so a shape retuned on
# one side would render one way in a freshly switched card and another way after
# reload, which is exactly the kind of drift nobody notices until a screenshot
# looks wrong.
#
# Parsing the JS with a regex is deliberate: it is a data table, not logic, and
# a real JS runtime is a heavy dependency for reading ten literals.
class NpsVesselParityTest < ActiveSupport::TestCase
  JS = Rails.root.join("app/javascript/lib/nps_vessels.js").read

  def js_vessels
    body = JS[/const NPS_VESSELS = \{(.+?)\n\}/m, 1]
    assert body, "NPS_VESSELS is gone from lib/nps_vessels.js or has been reshaped"
    body.scan(/^\s*(\w+):\s*\{([^}]*)\}/).to_h do |name, fields|
      attrs = fields.scan(/(\w+):\s*(?:"([^"]*)"|(-?\d+)|null)/).to_h do |k, str, num|
        [ k, str || (num && num.to_i) ]
      end
      [ name, attrs ]
    end
  end

  test "every vessel exists on both sides with the same geometry" do
    js = js_vessels
    assert_equal NpsHelper::NPS_VESSELS.keys.sort, js.keys.sort,
                 "the Ruby and JS vessel lists have diverged"

    NpsHelper::NPS_VESSELS.each do |name, rb|
      their = js.fetch(name)
      %w[w cx hw top bottom].each do |field|
        assert_equal rb[field.to_sym], their[field],
                     "#{name}.#{field}: Ruby says #{rb[field.to_sym].inspect}, JS says #{their[field].inspect}"
      end
      assert_equal rb[:path], their["path"], "#{name}.path has drifted between Ruby and JS"
    end
  end

  test "the shared scale and stroke constants agree" do
    {
      "VESSEL_H"    => NpsHelper::VESSEL_H,
      "WIDTH_SCALE" => NpsHelper::WIDTH_SCALE,
      "STROKE_W"    => NpsHelper::STROKE_W
    }.each do |name, ruby_value|
      js_value = JS[/^(?:export )?const #{name}\s*=\s*(\d+)/, 1]
      assert js_value, "#{name} is missing from lib/nps_vessels.js"
      assert_equal ruby_value, js_value.to_i, "#{name} differs between Ruby and JS"
    end
  end

  # The interior bounds are what make "0" empty and the last step brim-full, and
  # what the digit column is inset by. A bound outside its own path would put
  # the liquid somewhere the vessel isn't.
  test "every vessel's interior bounds lie inside its own viewBox and read the right way round" do
    NpsHelper::NPS_VESSELS.each do |name, v|
      assert v[:top] < v[:bottom], "#{name}: top must be above bottom"
      assert v[:top] >= 0,                  "#{name}: top escapes the viewBox"
      assert v[:bottom] <= NpsHelper::VESSEL_H, "#{name}: bottom escapes the viewBox"

      ys = v[:path].scan(/[-\d.]+,(-?[\d.]+)/).flatten.map(&:to_f)
      assert_in_delta ys.min, v[:top],    16, "#{name}: top is nowhere near the top of its path"
      assert_in_delta ys.max, v[:bottom], 16, "#{name}: bottom is nowhere near the foot of its path"
    end
  end

  # The custom properties the stage emits are the contract between the helper
  # and the stylesheet; a rename on either side silently un-styles the card.
  test "the stage style emits every property the stylesheet reads" do
    css   = Rails.root.join("app/assets/tailwind/application.css").read
    style = nps_stage_style("pill")

    %w[--nps-aspect --nps-top --nps-travel --nps-top-f --nps-bot-f].each do |prop|
      assert_includes style, "#{prop}:", "nps_stage_style no longer emits #{prop}"
      assert_includes css, "var(#{prop}", "application.css never reads #{prop}"
    end

    pill = NpsHelper::NPS_VESSELS.fetch("pill")
    assert_includes style, "--nps-travel: #{pill[:bottom] - pill[:top]}px"
    assert_includes style, "--nps-aspect: #{pill[:w] * NpsHelper::WIDTH_SCALE} / #{NpsHelper::VESSEL_H}"
  end

  # ── The creator's pick ────────────────────────────────────────────────────
  # The picker's groups are a hand-written table beside a hand-written drawing
  # table, and the two are only useful together: a vessel that can be drawn but
  # is in no group is unreachable, and a group naming a vessel that can't be
  # drawn is a tile that renders nothing. Neither failure shows up anywhere
  # else — the card still draws its themed default either way.
  # The themed pool is what a card falls back to when the creator has picked
  # nothing, and nps_vessel_for silently draws a pill for a name it doesn't
  # know — so a themed default that isn't drawable would not error, it would
  # just quietly give a whole category of Vertos the wrong container.
  test "every shape the theme can choose is one we can draw" do
    assert_empty ApplicationHelper::NPS_CONTAINER_SHAPES - NpsHelper::NPS_VESSELS.keys,
                 "a themed default names a vessel with no geometry — it will draw as a pill and " \
                 "nothing will say so"
  end

  test "every drawable vessel is offered exactly once by the picker" do
    grouped = NpsHelper::NPS_SHAPE_GROUPS.values.flatten
    assert_equal grouped.uniq, grouped, "a vessel is listed in more than one picker group"
    assert_equal NpsHelper::NPS_VESSELS.keys.sort, grouped.sort,
                 "the picker's groups and the drawing table have diverged — a vessel is either " \
                 "unreachable in the editor or offered as a tile that draws nothing"
  end

  # The whole point of the control: the card's own pick wins, and its absence
  # means "keep following the Verto's theme" rather than "freeze on whatever
  # rendered once".
  test "a card's own shape wins, and anything unusable falls back to the theme" do
    survey = Survey.new(theme: "Coffee culture")
    themed = nps_container_shape(survey)
    assert_equal "mug", themed, "the theme fixture stopped selecting a themed vessel"

    assert_equal "flask", nps_shape_slug({ "nps_shape" => "flask" }, survey)
    assert_equal themed,  nps_shape_slug({ "nps_shape" => "teapot" }, survey)
    assert_equal themed,  nps_shape_slug({}, survey)
    assert_equal themed,  nps_shape_slug(nil, survey)
  end

  # Same allowlist-or-drop contract range_theme has: the editor sends whatever
  # is on the card row, and only a drawable vessel on an NPS card survives.
  test "the sanitiser keeps a real vessel on an NPS card and drops everything else" do
    kept = Survey.sanitize_cards_images!([ { "type" => "nps", "nps_shape" => "beaker" } ])
    assert_equal "beaker", kept.first["nps_shape"]

    [ { "type" => "nps", "nps_shape" => "teapot" },
      { "type" => "multiple_choice", "nps_shape" => "beaker" } ].each do |card|
      out = Survey.sanitize_cards_images!([ card ])
      refute out.first.key?("nps_shape"),
             "nps_shape survived on #{card.inspect} — an unknown vessel or a non-NPS card"
    end
  end

  # ── The scale's own bounds ────────────────────────────────────────────────
  # Three copies of "how many stops an NPS may have": the Ruby that renders it,
  # the JS that lets a creator add and remove them, and the Rules of the Game
  # that score the card. A ceiling that drifts on one side is a ＋ that keeps
  # offering a twelfth stop the renderer will not lay out, or a rule that marks
  # a legal scale down.
  test "the step bounds agree between Ruby, JS and the rules" do
    js = Rails.root.join("app/javascript/lib/nps_vessels.js").read
    {
      "NPS_MIN_STEPS" => NpsHelper::NPS_MIN_STEPS,
      "NPS_MAX_STEPS" => NpsHelper::NPS_MAX_STEPS
    }.each do |name, ruby_value|
      found = js[/^export const #{name}\s*=\s*(\d+)/, 1]
      assert found, "#{name} is missing from lib/nps_vessels.js"
      assert_equal ruby_value, found.to_i, "#{name} differs between Ruby and JS"
    end

    assert_equal NpsHelper::NPS_STEPS, NpsHelper::NPS_MAX_STEPS,
                 "the ceiling has drifted off the classic scale it is derived from"

    rules = Rails.root.join("app/javascript/lib/verto_rules.js").read
    exact = rules[/nps:\s*\{\s*exact:\s*(\d+)\s*\}/, 1]
    assert exact, "COUNT_RULES no longer states an exact count for nps"
    assert_equal NpsHelper::NPS_STEPS, exact.to_i,
                 "the Rules of the Game score an NPS against a different number of points " \
                 "than the classic scale has"
  end

  # The three states, which is the whole reason this ships without a migration.
  test "a card is classic until its labels or its creator say otherwise" do
    refute nps_custom_scale?({ "type" => "nps" }),
           "a card with no labels at all is the classic scale — it renders as 0-10"
    refute nps_custom_scale?({ "type" => "nps", "options" => nps_default_labels }),
           "a card sitting on 0-10 is the classic scale, flag or no flag"

    assert nps_custom_scale?({ "type" => "nps", "options" => %w[Never Sometimes Always] }),
           "a deck already carrying its own scale must keep reading as custom — otherwise this " \
           "change locks every one of them and replaces their labels"
    assert nps_custom_scale?({ "type" => "nps", "options" => nps_default_labels,
                               "nps_custom_scale" => true }),
           "the creator's own switch has to outrank the labels, or unlocking a 0-10 card and " \
           "reloading would lock it straight back"
  end

  test "the sanitiser stores the unlock only where it means something" do
    kept = Survey.sanitize_cards_images!([ { "type" => "nps", "nps_custom_scale" => true } ])
    assert_equal true, kept.first["nps_custom_scale"]

    [ { "type" => "nps", "nps_custom_scale" => false },
      { "type" => "nps", "nps_custom_scale" => "yes" },
      { "type" => "multiple_choice", "nps_custom_scale" => true } ].each do |card|
      out = Survey.sanitize_cards_images!([ card ])
      refute out.first.key?("nps_custom_scale"),
             "nps_custom_scale survived on #{card.inspect} — there must be exactly one " \
             "representation of 'classic', which is the key being absent"
    end
  end

  private

  # nps_stage_style is a view helper; give the test the module's own methods.
  include NpsHelper
  # …and nps_shape_slug falls back through ApplicationHelper#nps_container_shape,
  # which is a sibling helper rather than part of this module.
  include ApplicationHelper
end
