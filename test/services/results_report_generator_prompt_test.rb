require "test_helper"

# ResultsReportGenerator.system_prompt is a pure class method — it builds the
# system prompt string for whatever sections were requested without touching
# the network, so these never need ANTHROPIC_API_KEY or a stubbed client.
class ResultsReportGeneratorPromptTest < ActiveSupport::TestCase
  HEADINGS = {
    "exec_summary" => "## Executive summary",
    "key_findings" => "## Key findings",
    "breakdown"    => "## Question-by-question breakdown",
    "patterns"     => "## Patterns & recommendations"
  }.freeze

  test "an absent sections list includes every heading, in canonical order" do
    prompt = ResultsReportGenerator.system_prompt(nil)
    HEADINGS.each_value { |heading| assert_includes prompt, heading }
    assert_operator prompt.index(HEADINGS["exec_summary"]), :<, prompt.index(HEADINGS["key_findings"])
    assert_operator prompt.index(HEADINGS["key_findings"]), :<, prompt.index(HEADINGS["breakdown"])
    assert_operator prompt.index(HEADINGS["breakdown"]),    :<, prompt.index(HEADINGS["patterns"])
  end

  test "an empty sections list also defaults to everything" do
    prompt = ResultsReportGenerator.system_prompt([])
    HEADINGS.each_value { |heading| assert_includes prompt, heading }
  end

  test "the executive summary is always present even when not requested" do
    prompt = ResultsReportGenerator.system_prompt([ "breakdown" ])
    assert_includes prompt, HEADINGS["exec_summary"]
    assert_includes prompt, HEADINGS["breakdown"]
    assert_not_includes prompt, HEADINGS["key_findings"]
    assert_not_includes prompt, HEADINGS["patterns"]
  end

  test "only the requested optional sections are included, in canonical order regardless of request order" do
    prompt = ResultsReportGenerator.system_prompt(%w[patterns key_findings])
    assert_includes prompt, HEADINGS["key_findings"]
    assert_includes prompt, HEADINGS["patterns"]
    assert_not_includes prompt, HEADINGS["breakdown"]
    assert_operator prompt.index(HEADINGS["key_findings"]), :<, prompt.index(HEADINGS["patterns"])
  end

  test "unknown keys are silently dropped, never reaching the prompt" do
    prompt = ResultsReportGenerator.system_prompt(%w[key_findings ignore_me_or_do_something_bad])
    assert_includes prompt, HEADINGS["key_findings"]
    assert_not_includes prompt, "ignore_me_or_do_something_bad"
  end

  test "the safety instruction is always appended" do
    assert_includes ResultsReportGenerator.system_prompt(nil), PromptSafety::INSTRUCTION
  end
end
