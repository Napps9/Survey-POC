class SurveysController < ApplicationController
  include AggregatesSurveyResults
  layout "fullscreen", only: [ :show, :new ]

  before_action :require_creator_org!
  before_action :require_admin!,       only: [ :destroy ]
  before_action :set_survey,           only: [ :show, :publish, :update_settings ]
  before_action :set_survey_including_archived, only: [ :results ]

  def index
    kept_surveys = Current.organisation.surveys.kept.includes(:responses).order(updated_at: :desc)
    @surveys          = kept_surveys
    @archived_surveys = Current.organisation.surveys.archived.includes(:responses).order(deleted_at: :desc)
    @total_responses  = Current.organisation.surveys.kept.joins(:responses).count
    render :index, layout: "fullscreen"
  end

  def new
  end

  def show
    render :show
  end

  def generate
    theme        = params[:theme].to_s.strip
    audience_age = params[:audience_age].to_s.strip
    key_insight  = params[:key_insight].to_s.strip
    notes        = params[:notes].to_s.strip
    show_compare = ActiveModel::Type::Boolean.new.cast(params[:show_results_comparison])
    palette      = BrandPalette.sanitize(params[:brand_palette])

    if theme.empty? || audience_age.empty? || key_insight.empty?
      flash.now[:alert] = "Tell us what your Verto's about, who's answering, and what you want to learn — those three are required."
      return render :new, status: :unprocessable_entity
    end

    result = SurveyGenerator.new.call(
      theme: theme,
      audience_age: audience_age,
      key_insight: key_insight,
      notes: notes
    )

    @survey = Current.organisation.surveys.create!(
      title:        result["title"],
      description:  result["description"],
      theme:        result["theme"].presence || theme,
      audience_age: result["audience_age"].presence || audience_age,
      key_insight:  result["key_insight"].presence || key_insight,
      cards:        result["cards"],
      show_results_comparison: show_compare,
      brand_palette: palette.presence
    )

    # Remember the palette as the company default so the next Verto inherits it.
    Current.organisation.update(default_brand_palette: palette) if palette.present?

    redirect_to survey_path(@survey)
  rescue => e
    Rails.logger.error("[SurveyGenerator] #{e.class}: #{e.message}")
    flash.now[:alert] = "We couldn't generate your Verto. Try again in a moment."
    render :new, status: :unprocessable_entity
  end

  def update
    survey = Current.organisation.surveys.kept.find(params[:id])
    payload = JSON.parse(request.body.read)

    # Only touch the attributes present in the payload, so the brand-colour
    # PATCH (which sends just `brand_palette`) doesn't wipe title/cards, and the
    # editor autosave (title/description/cards) doesn't touch the palette.
    attrs = {}
    attrs[:title]       = payload["title"]       if payload.key?("title")
    attrs[:description] = payload["description"] if payload.key?("description")
    if payload.key?("cards")
      attrs[:cards]                          = payload["cards"]
      attrs[:results_summary]                = nil
      attrs[:results_summary_response_count] = nil
    end
    attrs[:brand_palette] = BrandPalette.sanitize(payload["brand_palette"]).presence if payload.key?("brand_palette")

    survey.update!(attrs)

    render json: { ok: true, id: survey.id, updated_at: survey.updated_at }
  rescue => e
    Rails.logger.error("[SurveysController#update] #{e.class}: #{e.message}")
    render json: { ok: false, error: e.message }, status: :unprocessable_entity
  end

  def publish
    @survey.update!(
      publish_token: @survey.publish_token || SecureRandom.urlsafe_base64(18),
      published_at:  @survey.published_at  || Time.current
    )
    redirect_to survey_path(@survey)
  end

  def update_settings
    show_compare = ActiveModel::Type::Boolean.new.cast(params[:show_results_comparison])
    @survey.update!(show_results_comparison: show_compare)
    redirect_to survey_path(@survey)
  end

  def destroy
    survey = Current.organisation.surveys.kept.find(params[:id])
    survey.archive!
    redirect_to root_path, notice: "“#{survey.theme.presence || survey.title.presence || 'Verto'}” deleted. Responders' link no longer works; results stay in your Archived list."
  end

  def results
    @responses  = @survey.responses.where(status: "completed").order(created_at: :desc)
    @total      = @responses.count
    @aggregated = aggregate_results(Array(@survey.cards), @responses)
    render :results, layout: "fullscreen"
  end

  private

  def set_survey
    @survey = Current.organisation.surveys.kept.find(params[:id])
  end

  def set_survey_including_archived
    @survey = Current.organisation.surveys.find(params[:id])
  end
end
