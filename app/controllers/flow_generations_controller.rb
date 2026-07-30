# Polling endpoint for a flow generation started by SurveysController#generate_flow.
#
# The job stores card JSON; this turns it into the editor markup the client
# splices in. That split is deliberate — Claude is the slow part and belongs on a
# queue, while rendering a card row is fast and needs a view context a job hasn't
# got.
class FlowGenerationsController < ApplicationController
  include RendersCardHtml

  # GET /flow_generations/:id
  def show
    generation = find_generation

    # A job that died without reporting back — the memory watchdog recycles Puma
    # (and Solid Queue with it) near the container's memory limit, and a deploy
    # does the same. Surface it rather than letting the editor poll forever.
    generation.fail!("That took longer than expected. Please try again.") if generation.stale?

    if generation.succeeded?
      survey = generation.survey
      cards  = Array(generation.cards).map do |card|
        { cid: card["cid"], html: render_card_html(survey, card) }
      end
      return render json: { ok: true, status: "succeeded", name: generation.flow_name, cards: cards }
    end

    if generation.failed?
      return render json: { ok: false, status: "failed", error: generation.error_message },
                    status: :unprocessable_entity
    end

    render json: { ok: true, status: generation.status }
  rescue ActiveRecord::RecordNotFound
    render json: { ok: false, error: "That flow generation is no longer available." }, status: :not_found
  end

  private

    # Scoped through the organisation's surveys, so one account can't poll
    # another's generation.
    def find_generation
      FlowGeneration.joins(:survey)
                    .where(surveys: { organisation_id: Current.organisation.id })
                    .find(params[:id])
    end
end
