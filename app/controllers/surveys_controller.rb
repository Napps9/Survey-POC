class SurveysController < ApplicationController
  layout "fullscreen", only: :show

  # JSON updates from the inline editor are same-origin fetches without CSRF tokens.
  protect_from_forgery with: :null_session, only: :update

  def new
  end

  def show
    @survey = Survey.find(params[:id])
    render :show
  end

  def generate
    theme        = params[:theme].to_s.strip
    audience_age = params[:audience_age].to_s.strip
    key_insight  = params[:key_insight].to_s.strip
    notes        = params[:notes].to_s.strip

    if theme.empty? || audience_age.empty? || key_insight.empty?
      flash.now[:alert] = "Theme, audience age, and key insight are all required."
      return render :new, status: :unprocessable_entity
    end

    result = SurveyGenerator.new.call(
      theme: theme,
      audience_age: audience_age,
      key_insight: key_insight,
      notes: notes
    )

    @survey = Survey.create!(
      title:        result["title"],
      description:  result["description"],
      theme:        result["theme"].presence || theme,
      audience_age: result["audience_age"].presence || audience_age,
      key_insight:  result["key_insight"].presence || key_insight,
      cards:        result["cards"]
    )

    redirect_to survey_path(@survey)
  rescue => e
    Rails.logger.error("[SurveyGenerator] #{e.class}: #{e.message}")
    flash.now[:alert] = "Generation failed: #{e.message}"
    render :new, status: :unprocessable_entity
  end

  def update
    survey = Survey.find(params[:id])
    payload = JSON.parse(request.body.read)

    survey.update!(
      title:       payload["title"],
      description: payload["description"],
      cards:       payload["cards"]
    )

    render json: { ok: true, id: survey.id, updated_at: survey.updated_at }
  rescue => e
    Rails.logger.error("[SurveysController#update] #{e.class}: #{e.message}")
    render json: { ok: false, error: e.message }, status: :unprocessable_entity
  end

  private

  def survey_payload(s)
    {
      "id"           => s.id,
      "title"        => s.title,
      "description"  => s.description,
      "theme"        => s.theme,
      "audience_age" => s.audience_age,
      "key_insight"  => s.key_insight,
      "cards"        => s.cards
    }
  end
end
