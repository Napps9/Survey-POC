require "test_helper"

# Framework loads the Awareness/Intention/Agency taxonomy + the enabling
# conditions from config/competencies.yml — the single source of truth shared
# by the generator schemas, the prompts, and the editor's "Why" tab.
class FrameworkTest < ActiveSupport::TestCase
  test "competency keys are awareness, intention, agency in activation order" do
    assert_equal %w[awareness intention agency], Framework::COMPETENCY_KEYS
  end

  test "condition keys cover the six enabling conditions" do
    assert_equal %w[wellbeing belonging perceived_support confidence_capability
                    institutional_responsiveness safety_protection],
                 Framework::CONDITION_KEYS
  end

  test "competency / condition metadata carries a label, blurb and accent" do
    agency = Framework.competency("agency")
    assert_equal "Agency", agency["label"]
    assert agency["blurb"].present?
    assert_match(/\A#[0-9A-Fa-f]{6}\z/, agency["accent"])

    assert_equal "Wellbeing", Framework.condition("wellbeing")["label"]
  end

  test "unknown keys are safe: empty hash and false predicates" do
    assert_equal({}, Framework.competency("nope"))
    assert_equal({}, Framework.condition("nope"))
    refute Framework.competency?("nope")
    refute Framework.condition?(nil)
    assert Framework.competency?("agency")
    assert Framework.condition?("belonging")
  end

  test "to_json exposes both groups for the editor JS" do
    data = JSON.parse(Framework.to_json)
    assert_equal Framework::COMPETENCY_KEYS, data["competencies"].keys
    assert_equal Framework::CONDITION_KEYS, data["conditions"].keys
  end
end
