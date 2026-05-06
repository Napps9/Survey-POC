class SurveysController < ApplicationController
  layout "fullscreen", only: :show

  # JSON updates from the inline editor are same-origin fetches without CSRF tokens.
  protect_from_forgery with: :null_session, only: :update

  before_action :set_survey, only: [:show, :publish, :results]

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

  def publish
    @survey.update!(
      publish_token: @survey.publish_token || SecureRandom.urlsafe_base64(18),
      published_at:  @survey.published_at  || Time.current
    )
    redirect_to survey_path(@survey)
  end

  def results
    @responses  = @survey.responses.where(status: "completed").order(created_at: :desc)
    @total      = @responses.count
    @aggregated = aggregate_results(Array(@survey.cards), @responses)
    render :results, layout: "fullscreen"
  end

  private

  def set_survey
    @survey = Survey.find(params[:id])
  end

  def aggregate_results(cards, responses)
    cards.map.with_index do |card, idx|
      key  = idx.to_s
      type = card["type"].to_s
      vals = responses.filter_map { |r| r.answers[key]&.dig("value") }
      case type
      when "multiple_choice", "yes_no", "select_one_grid"
        counts = Hash.new(0).tap { |h| vals.each { |v| h[v.to_s] += 1 } }
        { type:, card:, total: vals.size, counts: }
      when "select_many", "select_many_grid"
        counts = Hash.new(0).tap { |h| vals.each { |a| Array(a).each { |v| h[v.to_s] += 1 } } }
        { type:, card:, total: vals.size, counts: }
      when "tap_card"
        counts = {}
        vals.each { |obj| obj.each { |l, d| (counts[l] ||= { "yes" => 0, "no" => 0 })[d] += 1 } if obj.is_a?(Hash) }
        { type:, card:, total: vals.size, counts: }
      when "range"
        counts = Hash.new(0).tap { |h| vals.each { |v| h[v.to_i] += 1 } }
        { type:, card:, total: vals.size, counts: }
      when "rating"
        counts = Hash.new(0).tap { |h| vals.each { |v| h[v.to_i] += 1 } }
        avg = vals.any? ? (vals.sum(&:to_f) / vals.size).round(1) : 0.0
        { type:, card:, total: vals.size, counts:, avg: }
      when "open_ended"
        { type:, card:, total: vals.size, texts: vals.map(&:to_s).reject(&:blank?) }
      when "static_page"
        { type:, card:, total: vals.size, completed: vals.count { |v| v == true } }
      else
        { type:, card:, total: responses.count, counts: {} }
      end
    end
  end

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
