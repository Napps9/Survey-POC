require "test_helper"

# The vessel geometry exists TWICE: NpsHelper draws it server-side, and
# type_panel_controller.js redraws it when a creator switches a card's type to
# NPS without a round-trip. Both files say "keep the two in sync" and nothing
# checked that they were — so a shape retuned on one side would render one way
# in a freshly switched card and another way after reload, which is exactly the
# kind of drift nobody notices until a screenshot looks wrong.
#
# Parsing the JS with a regex is deliberate: it is a data table, not logic, and
# a real JS runtime is a heavy dependency for reading ten literals.
class NpsVesselParityTest < ActiveSupport::TestCase
  JS = Rails.root.join("app/javascript/controllers/type_panel_controller.js").read

  def js_vessels
    body = JS[/const NPS_VESSELS = \{(.+?)\n\}/m, 1]
    assert body, "NPS_VESSELS is gone from type_panel_controller.js or has been reshaped"
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
      js_value = JS[/^const #{name}\s*=\s*(\d+)/, 1]
      assert js_value, "#{name} is missing from type_panel_controller.js"
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

  private

  # nps_stage_style is a view helper; give the test the module's own methods.
  include NpsHelper
end
