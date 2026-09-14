# The respondent dashboard's view-side lookups. Both mirror what the creator's
# tile does (surveys/_dashboard_card), on purpose: the face a Verto wears and
# the number of questions it says it has should be the same on both sides.
module YouHelper
  # The welcome card's art, else the first card that carries any. A Verto with
  # neither has no cover and the card draws a flat gradient band instead.
  def verto_cover_image(survey)
    cards   = Array(survey.cards)
    welcome = cards.find { |c| c["type"].to_s == "welcome_card" }
    welcome&.dig("image").presence || cards.map { |c| c["image"] }.find(&:present?)
  end

  # For the follow-up cards, whose Vertos are not in the controller's
  # @questions (that hash is keyed by the Vertos the account holds).
  def verto_question_count(survey)
    Array(survey.cards).count { |c| CardTypes.question?(c["type"]) }
  end
end
