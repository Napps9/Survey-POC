# Generates one flow's cards: a FlowGenerator call, then a translation pass —
# one Claude call for the flow plus one per secondary locale. This is the work
# that used to run inline on a Puma request thread (see FlowGeneration).
#
# Everything needing the request context — authorisation, the editing lock, param
# validation — has already happened in SurveysController#generate_flow. This job
# has no Current.organisation and deliberately makes no permission decisions of
# its own.
class GenerateFlowJob < ApplicationJob
  queue_as :default

  # No retries, for the same reason as BuildVertoJob: a silent retry would bill
  # the account for a second generation while the creator watches a spinner. A
  # failure surfaces its reason and the creator chooses whether to try again.
  discard_on StandardError do |job, error|
    generation = FlowGeneration.find_by(id: job.arguments.first)
    ErrorReporting.report("GenerateFlowJob", error, flow_generation_id: generation&.id)
    generation&.fail!(VertoGeneration.friendly_error(error))
  end

  def perform(flow_generation_id)
    generation = FlowGeneration.find_by(id: flow_generation_id)
    return unless generation
    # Already handled — a duplicate delivery must not bill a second generation.
    return if generation.finished? || generation.running?

    generation.start!
    survey = generation.survey
    p      = generation.payload

    result = FlowGenerator.new.call(
      prompt:         p["prompt"].to_s,
      answer:         p["answer"].presence,
      entry_text:     p["entry_text"].presence,
      theme:          survey.theme,
      audience_age:   survey.audience_age,
      key_insight:    survey.key_insight,
      existing_cards: Array(survey.cards),
      locale:         survey.default_locale
    )

    # Stamp cids now (same as render_card) so each card is a valid routing target
    # the moment the client splices it in.
    cards = Array(result["cards"]).each { |card| card["cid"] = "c_#{SecureRandom.hex(3)}" }
    # One translation pass for the whole flow, not one per card — the difference
    # between 5 Claude calls and 30 on a five-language Verto.
    cards = VertoGeneration.translate_cards!(cards, survey)

    generation.succeed!(cards: cards, flow_name: result["name"])
  end
end
