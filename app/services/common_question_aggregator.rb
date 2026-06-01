# Aggregates responses to a CommonQuestionSet across every Verto that
# attached it. Clusters answers by common_question_id (the stable identity
# stamped into each Survey card's JSON snapshot), so wording drift between
# snapshots doesn't fragment the totals.
#
# Returns four values:
#   per_question      Array of aggregate row hashes, one per master CommonQuestion
#                     (using the master text as the label). Each row reuses the
#                     same shape AggregatesSurveyResults#aggregate_results emits
#                     so the view can render with existing card-type templates.
#   snapshot_variants Hash<cq_id, Hash<snapshot_text, [survey_id, ...]>> — used
#                     by the view to disclose wording drift across attaches.
#   total_surveys     Count of surveys contributing data.
#   total_responses   Count of responses across those surveys.
class CommonQuestionAggregator
  include AggregatesSurveyResults

  def initialize(set, surveys)
    @set      = set
    @surveys  = Array(surveys).select { |s| s.is_a?(Survey) }
  end

  def aggregate
    per_question_answers = Hash.new { |h, cq_id| h[cq_id] = [] }
    snapshot_variants    = Hash.new { |h, cq_id| h[cq_id] = Hash.new { |hh, k| hh[k] = [] } }
    total_responses      = 0

    @surveys.each do |survey|
      cards     = Array(survey.cards)
      cq_by_idx = {}

      cards.each_with_index do |card, idx|
        next unless card.is_a?(Hash) && card["common_question_set_id"] == @set.id
        cq_id = card["common_question_id"]
        next unless cq_id
        cq_by_idx[idx] = cq_id
        snapshot_text = card["text"].to_s
        snapshot_variants[cq_id][snapshot_text] << survey.id
      end

      next if cq_by_idx.empty?

      survey_responses = survey.responses.to_a
      total_responses += survey_responses.size

      survey_responses.each do |response|
        next unless response.answers.is_a?(Hash)
        cq_by_idx.each do |idx, cq_id|
          ans = response.answers[idx.to_s]
          per_question_answers[cq_id] << ans if ans.is_a?(Hash) && ans["value"].present?
        end
      end
    end

    per_question = @set.common_questions.map do |cq|
      fake_card    = cq.to_card
      fake_resps   = per_question_answers[cq.id].map { |a| Response.new(answers: { "0" => a }) }
      row          = aggregate_results([ fake_card ], fake_resps).first || { card: fake_card, type: cq.card_type, total: 0 }
      row.merge(common_question: cq, drift?: snapshot_variants[cq.id].keys.reject { |t| t == cq.text }.any?)
    end

    [ per_question, snapshot_variants, @surveys.count { |s| s.responses.any? }, total_responses ]
  end
end
