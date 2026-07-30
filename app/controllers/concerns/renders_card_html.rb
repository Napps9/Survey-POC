# Renders one card as its editor row, for the endpoints that hand the client
# ready-made markup to splice in (render_card, generate_card, optimise_card, and
# the flow-generation poll).
#
# Shared as a concern because FlowGenerationsController needs it too: the slow
# Claude work moved to a job, but turning card JSON into editor markup stayed in
# a request — it's fast, and it needs a view context a job hasn't got.
module RendersCardHtml
  extend ActiveSupport::Concern

  private

  # `idx` is the position the card will occupy. Omitted means "appended", which
  # is what the generators do.
  def render_card_html(survey, card, idx: nil)
    # The card_row partial (and its children) read @survey — e.g. for the
    # "recommended for this card" images. The generator endpoints don't go
    # through set_survey, so make sure it's set or those renders 500 on nil.
    @survey ||= survey
    existing = Array(survey.cards)
    if idx
      total_q = existing.count { |c| CardTypes.question?(c["type"]) }
      q_idx   = existing.first(idx + 1).count { |c| CardTypes.question?(c["type"]) }
    else
      idx     = existing.size
      total_q = existing.count { |c| CardTypes.question?(c["type"]) } +
                (CardTypes.question?(card["type"]) ? 1 : 0)
      q_idx   = CardTypes.question?(card["type"]) ? total_q : 0
    end
    render_to_string(
      partial: "surveys/card_row",
      formats: [ :html ],
      locals:  { card: card, idx: idx, q_idx: q_idx, total_q: total_q,
                 default_locale: survey.default_locale, quiz: survey.quiz?,
                 tokenisation: survey.tokenisation_enabled? }
    )
  end
end
