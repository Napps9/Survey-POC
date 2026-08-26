# Ask-once answers this respondent already gave to THIS Verto, found by the
# code they just typed.
#
# ── What this is for ───────────────────────────────────────────────────────
# "Ask once" was, until now, a promise made to a BROWSER: the answer lives in
# localStorage under a device-minted uuid, so the same person on a new phone —
# or after clearing site data, or in a private window — is asked everything
# again. That is the opposite of what the setting says, and the fix has to be
# an identity the respondent carries rather than one their device does. The
# respondent code already is exactly that.
#
# ── What it costs, stated plainly ──────────────────────────────────────────
# The code is chosen to be MEMORABLE ("sam14", "blue7", "mum1970"), which makes
# it guessable, and this endpoint returns answers under it. Everything else the
# player exposes is either the respondent's own or aggregate; this is the one
# place a stranger's answer could come back. So:
#
#   * it is off unless the creator turned it on, on the card itself;
#   * it returns ONLY answers to cards currently flagged ask-once — untoggling
#     ask-once stops recall for that card immediately, with no migration;
#   * it never returns a graded or token-awarding card's answer. Handing back a
#     mark or points for a question this run did not answer, which locked_merge
#     would then commit as immutable, is a scoring hole rather than a
#     convenience;
#   * it returns NOTHING about demographics, region, locale, contact details,
#     score, totals, timestamps, counts, or any other response field;
#   * it says nothing about whether the code exists. Unknown code, blank code,
#     recall off, nothing recallable — one shape for all of them. (A non-empty
#     answer set still implies existence. That is unavoidable and worth writing
#     down rather than pretending otherwise.)
#
# ── Collisions fail closed ─────────────────────────────────────────────────
# Two people can invent "sam14"; nothing has ever stopped them, and until now
# the only consequence was a slightly wrong returning-respondent count. With
# recall it would be disclosure. So a card whose stored answers DISAGREE under
# one digest is dropped from the payload entirely. The legitimate same-person
# case is unaffected — the player re-submits the remembered answer identically
# every run — and a collision (or a person who genuinely changed their mind
# between waves) degrades to "the question gets asked again", which is the
# pre-feature behaviour. Failing toward asking again is the recoverable
# direction, the same reasoning VertoGeneration#write_cards_if_unchanged! uses.
class RespondentRecall
  # Enough runs to establish agreement without reading a whole wave into memory
  # for one keystroke.
  MAX_RESPONSES = 50

  def initialize(survey)
    @survey = survey
  end

  # Returns { "<cid or index>" => { "type" =>, "value" =>, "other" => } }, in
  # exactly the shape player_controller's _capture stores and _isAnswerGiven
  # reads — so the client can put it straight into its answer map and the
  # ordinary save payload carries it unchanged.
  def answers_for(digest)
    return {} unless @survey.respondent_code_recall?
    return {} if digest.blank?
    return {} if recallable_cards.empty?

    rows = @survey.responses
                  .where(respondent_code_digest: digest)
                  .order(id: :desc)
                  .limit(MAX_RESPONSES)
                  .pluck(:answers)
    return {} if rows.empty?

    recallable_cards.each_with_object({}) do |(index, card), out|
      entry = agreed_answer(rows, index.to_s)
      next if entry.nil?

      out[card["cid"].presence || index.to_s] = entry
    end
  end

  private

  # Card index => card, for every card this Verto may currently recall. Read
  # from the deck as it is NOW, so a creator untoggling ask-once takes effect
  # on the next request rather than needing anything backfilled.
  def recallable_cards
    @recallable_cards ||= begin
      excluded = @survey.graded_card_indices.to_set | @survey.token_awarding_indices.to_set
      Array(@survey.cards).each_with_index.filter_map do |card, index|
        next unless card.is_a?(Hash) && card["ask_once"] && CardTypes.question?(card["type"])
        next if excluded.include?(index)

        [ index, card ]
      end
    end
  end

  # The one answer every prior run agrees on, or nil. Disagreement is treated as
  # a possible code collision and dropped — see the header.
  def agreed_answer(rows, key)
    given = rows.filter_map { |answers| answers.is_a?(Hash) ? answers[key] : nil }
                .select { |entry| Response.answered_entry?(entry) }
    return nil if given.empty?
    return nil unless given.uniq.size == 1

    given.first
  end
end
