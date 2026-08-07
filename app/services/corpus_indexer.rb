# Turns one approved Verto's responses into the rows Ask Verto answers from.
#
# This is the only place respondent data is read for Ask Verto. It runs inside the
# owning account, aggregates with the app's existing AggregatesSurveyResults (so
# there is exactly one aggregation implementation in the codebase, not two that
# can disagree), applies small-cell suppression, and writes counts. Nothing that
# identifies a person is carried across.
#
# ── The prioritise trap ────────────────────────────────────────────────────────
# AggregatesSurveyResults stores a prioritise card's counts as a SUM OF 1-BASED
# RANKS (see accumulate_value: `st[:counts][label] += (i + 1)`), not as a
# frequency. It looks exactly like a count and it is the opposite of one — a
# LOWER number means a HIGHER priority. Indexed naively, "Money: 480" would be
# read by the model, and by any reader, as 480 people choosing money, when it
# means money was ranked highly. Every prioritise citation would be confidently
# wrong with no visible symptom.
#
# So prioritise is converted to a mean rank here and stored under a distinct
# shape ("mean_rank"), never as `distribution` counts. If a future card type
# accumulates something that isn't a frequency, it must be handled here too or
# excluded — INDEXABLE_TYPES is deliberately an allow-list for that reason.
class CorpusIndexer
  include AggregatesSurveyResults

  # Only these types produce a citable distribution. An allow-list, not a
  # deny-list: a new card type is silently absent from Ask Verto until someone
  # decides what citing it would mean, which is the safe direction to fail.
  #
  # Excluded on purpose:
  #   contact_form    collects a name and an email. Never.
  #   prioritise      rank sums, not counts — see above. Indexed separately.
  #   welcome_card,
  #   consent_gate,
  #   token_checkpoint   not questions.
  INDEXABLE_TYPES = %w[
    multiple_choice yes_no select_one_grid select_many select_many_grid
    scenario tap_card range nps rating open_ended
  ].freeze

  # Types whose distribution is a straight {label => count}.
  COUNT_TYPES = %w[
    multiple_choice yes_no select_one_grid select_many select_many_grid scenario
  ].freeze

  def self.indexable?(type) = INDEXABLE_TYPES.include?(type.to_s)

  def initialize(entry, themer: OpenTextThemer.new)
    @entry  = entry
    @survey = entry.survey
    @themer = themer
  end

  # Rebuild this entry's index in place.
  #
  # Rows are matched on `cid` and UPDATED rather than deleted and recreated, so a
  # corpus_question keeps its id across re-indexes. That id is the citation: a
  # delete-and-recreate would silently re-point every citation already stored on
  # an answered message.
  def call
    responses = @survey.responses.where(status: "completed")
    total     = responses.count
    return skip!(total) if total < CorpusEntry::MIN_SAMPLE_SIZE

    cards      = Array(@survey.cards)
    aggregated = aggregate_results(cards, responses)
    segments   = SegmentAggregator.new(@survey, cards).call

    seen_cids = []

    CorpusEntry.transaction do
      cards.each_with_index do |card, idx|
        type = card["type"].to_s
        next unless self.class.indexable?(type) || type == "prioritise"

        result = aggregated[idx]
        next if result.nil? || result[:total].to_i < CorpusEntry::MIN_SAMPLE_SIZE

        cid = card["cid"].presence || "idx_#{idx}"
        seen_cids << cid

        question = @entry.corpus_questions.find_or_initialize_by(cid: cid)
        question.assign_attributes(
          position:       idx,
          card_type:      type,
          question_text:  card["text"].to_s.presence || card["title"].to_s,
          options:        Array(card["options"]).map(&:to_s),
          theme:          card["theme"].presence || @survey.theme,
          distribution:   distribution_for(type, result, card),
          response_count: result[:total].to_i,
          segments:       segments[idx] || {}
        )
        question.save!

        index_quotes(question, result) if type == "open_ended"
      end

      # Questions that no longer exist in the deck (or fell below the sample
      # floor) leave the corpus. Their citations on old messages become stale,
      # which AskMessage#stale_sources surfaces — the right outcome, rather than
      # answering from a question that isn't there any more.
      @entry.corpus_questions.where.not(cid: seen_cids).destroy_all

      @entry.update!(indexed_at: Time.current, response_count: total)
    end

    @entry
  end

  private

  def skip!(total)
    # Below the floor the Verto contributes nothing, and any rows it had must go.
    CorpusEntry.transaction do
      @entry.corpus_questions.destroy_all
      @entry.update!(indexed_at: Time.current, response_count: total)
    end
    @entry
  end

  # The shape the tools read. Distinct shapes rather than one hash of counts,
  # because "48% chose this" and "this ranked 2.1 on average" are different claims
  # and a single shape would let the model state one as the other.
  def distribution_for(type, result, card)
    case type
    when *COUNT_TYPES
      stringify_counts(result[:counts])
    when "tap_card"
      # {label => {"yes"=>, "no"=>, "unsure"=>}} — already the right shape.
      result[:counts].transform_values { |v| v.is_a?(Hash) ? v.transform_values(&:to_i) : v.to_i }
    when "range", "nps"
      # Steps are indices into the card's option labels; resolve them here so a
      # citation reads "Very worried", not "step 3".
      labels = Array(card["options"]).map(&:to_s)
      result[:counts].each_with_object({}) do |(step, count), out|
        out[labels[step.to_i] || "Step #{step.to_i + 1}"] = count.to_i
      end
    when "rating"
      stringify_counts(result[:counts]).merge("avg" => result[:avg])
    when "prioritise"
      # See the class comment. counts[label] is a SUM OF RANKS; total is the
      # number of respondents who ordered the list. Mean rank is the only honest
      # reading, and it is stored under its own key so nothing can mistake it for
      # a frequency.
      total = result[:total].to_i
      return {} if total.zero?

      ranks = result[:counts].each_with_object({}) do |(label, rank_sum), out|
        out[label.to_s] = (rank_sum.to_f / total).round(2)
      end
      { "mean_rank" => ranks }
    when "open_ended"
      # Themes are filled in by index_quotes; the count is what's citable here.
      { "responses" => result[:total].to_i }
    else
      {}
    end
  end

  def stringify_counts(counts)
    counts.each_with_object({}) { |(k, v), out| out[k.to_s] = v.to_i }
  end

  # Open text: themes with counts, plus the quotes that survive redaction.
  def index_quotes(question, result)
    texts = Array(result[:texts]).select { |t| t.is_a?(String) }
    return if texts.empty?

    kept, drops = QuoteRedactor.redact_all(texts)
    themed = @themer.call(question_text: question.question_text, texts: kept)

    question.update!(
      distribution: {
        "responses" => result[:total].to_i,
        "themes"    => themed[:themes],
        "redacted"  => drops.transform_keys(&:to_s)
      }
    )

    question.corpus_quotes.destroy_all
    themed[:quotes].each do |quote|
      question.corpus_quotes.create!(body: quote[:body], theme: quote[:theme])
    end
  rescue => e
    # A Verto must still be citable for its closed questions when the theming
    # call fails. Quotes are the enrichment, not the point.
    ErrorReporting.report("CorpusIndexer#index_quotes", e, corpus_question_id: question.id)
    question.update!(distribution: { "responses" => result[:total].to_i })
  end
end
