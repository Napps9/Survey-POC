class SurveysController < ApplicationController
  include AggregatesSurveyResults
  include ResolvesResultSegments
  layout "fullscreen", only: [ :show, :new ]

  before_action :require_admin!,       only: [ :destroy, :destroy_forever, :bulk_archive, :bulk_destroy ]
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

    # Languages this Verto is built in. The primary (default_locale) is the
    # generation source and the canonical language answers align against; the
    # rest are translated from it.
    locales        = SupportedLocales.sanitize_list(params[:locales], fallback: [ Current.locale.to_s ])
    default_locale = SupportedLocales.coerce(params[:default_locale].presence || locales.first)
    locales        = ([ default_locale ] + locales).uniq

    if theme.empty? || audience_age.empty? || key_insight.empty?
      flash.now[:alert] = "Tell us what your Verto's about, who's answering, and what you want to learn — those three are required."
      return render :new, status: :unprocessable_entity
    end

    result = SurveyGenerator.new.call(
      theme: theme,
      audience_age: audience_age,
      key_insight: key_insight,
      notes: notes,
      locale: default_locale
    )

    @survey = Current.organisation.surveys.create!(
      title:        result["title"],
      description:  result["description"],
      theme:        result["theme"].presence || theme,
      audience_age: result["audience_age"].presence || audience_age,
      key_insight:  result["key_insight"].presence || key_insight,
      cards:        result["cards"],
      show_results_comparison: show_compare,
      brand_palette: palette.presence,
      default_locale: default_locale,
      locales:        locales
    )

    # Remember the palette as the company default so the next Verto inherits it.
    Current.organisation.update(default_brand_palette: palette) if palette.present?

    translate_survey!(@survey)

    if ActiveModel::Type::Boolean.new.cast(params[:populate_content])
      begin
        AssetPopulator.new(@survey).populate!
      rescue => e
        Rails.logger.error("[AssetPopulator] #{e.class}: #{e.message}")
      end
    end

    redirect_to survey_path(@survey)
  rescue => e
    Rails.logger.error("[SurveyGenerator] #{e.class}: #{e.message}")
    flash.now[:alert] = "We couldn't generate your Verto — #{friendly_generate_error(e)}"
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
    attrs[:background_image] = Survey.sanitize_background_image(payload["background_image"]) if payload.key?("background_image")

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

  def shuffle_assets
    survey = Current.organisation.surveys.kept.find(params[:id])
    AssetPopulator.new(survey, seed: SecureRandom.hex(4)).populate!
    redirect_to survey_path(survey)
  rescue => e
    Rails.logger.error("[SurveysController#shuffle_assets] #{e.class}: #{e.message}")
    redirect_to survey_path(survey), alert: "Couldn't shuffle assets — #{e.message}"
  end

  def destroy
    survey = Current.organisation.surveys.kept.find(params[:id])
    survey.archive!
    redirect_to root_path, notice: "“#{survey.theme.presence || survey.title.presence || 'Verto'}” deleted. Responders' link no longer works; results stay in your Archived list."
  end

  def destroy_forever
    survey = Current.organisation.surveys.archived.find(params[:id])
    name   = survey.theme.presence || survey.title.presence || "Verto"
    Survey.transaction { survey.destroy! }
    redirect_to root_path, notice: "“#{name}” permanently deleted. All responses and data have been erased."
  end

  def bulk_archive
    ids   = Array(params[:ids]).map(&:to_i).reject(&:zero?)
    count = 0
    Survey.transaction do
      Current.organisation.surveys.kept.where(id: ids).find_each do |s|
        s.archive!
        count += 1
      end
    end
    redirect_to root_path, notice: "#{count} #{'Verto'.pluralize(count)} deleted. Responders' links no longer work; results stay in your Archived list."
  end

  def bulk_destroy
    ids   = Array(params[:ids]).map(&:to_i).reject(&:zero?)
    count = 0
    Survey.transaction do
      Current.organisation.surveys.where(id: ids).find_each do |s|
        s.destroy!
        count += 1
      end
    end
    redirect_to root_path, notice: "#{count} #{'Verto'.pluralize(count)} permanently deleted. All responses and data have been erased."
  end

  def results
    base, @segments, @active_segment = resolve_result_segments(@survey, params[:segment])
    @overall_total  = base.count

    @responses  = @active_segment[:scope]
    @total      = @active_segment[:count]
    @aggregated = aggregate_results(Array(@survey.cards), @responses)
    render :results, layout: "fullscreen"
  end

  # POST /surveys/:id/generate_card
  # Generates a single new question card using Claude, renders its HTML partial.
  def generate_card
    survey = Current.organisation.surveys.kept.find(params[:id])

    card = SingleQuestionGenerator.new.call(
      theme:          survey.theme,
      audience_age:   survey.audience_age,
      key_insight:    survey.key_insight,
      existing_cards: Array(survey.cards),
      locale:         survey.default_locale
    )
    card = translate_card!(card, survey)

    html = render_card_html(survey, card)
    render json: { ok: true, html: html }
  rescue => e
    Rails.logger.error("[SurveysController#generate_card] #{e.class}: #{e.message}")
    render json: { ok: false, error: e.message }, status: :unprocessable_entity
  end

  # POST /surveys/:id/render_card
  # Renders the HTML partial for a given card JSON (used by "Start from Blank" flow).
  def render_card
    survey = Current.organisation.surveys.kept.find(params[:id])
    card   = JSON.parse(request.body.read)

    html = render_card_html(survey, card)
    render json: { ok: true, html: html }
  rescue => e
    Rails.logger.error("[SurveysController#render_card] #{e.class}: #{e.message}")
    render json: { ok: false, error: e.message }, status: :unprocessable_entity
  end

  private

  def set_survey
    @survey = Current.organisation.surveys.kept.find(params[:id])
  end

  # Turn an exception from the generate pipeline into something the operator
  # can act on. For Anthropic API errors we surface the upstream message
  # (e.g. "credit balance too low", "rate limit") rather than the generic
  # "try again" line, which sent us in circles diagnosing the bug.
  def friendly_generate_error(e)
    api_msg = anthropic_api_message(e)
    return api_msg if api_msg.present?

    msg = e.message.to_s.strip
    msg = msg.first(200) + "…" if msg.length > 200
    msg.presence || "#{e.class.name.split('::').last}. Check the server logs."
  end

  def anthropic_api_message(e)
    return nil unless defined?(Anthropic::Errors::APIError) && e.is_a?(Anthropic::Errors::APIError)
    body = e.respond_to?(:body) ? e.body : nil
    return nil unless body.is_a?(Hash)
    body.dig(:error, :message) || body.dig("error", "message")
  end

  # Translate the survey's primary cards into each secondary language and store
  # the result in each card's i18n map. Per-language failures are non-fatal —
  # that language simply falls back to the primary text until re-translated.
  def translate_survey!(survey)
    return unless survey.secondary_locales.any?

    cards  = Array(survey.cards)
    source = survey.default_locale
    survey.secondary_locales.each do |loc|
      translated = SurveyTranslator.new.call(cards: cards, target_locale: loc, source_locale: source)
      cards = Survey.merge_card_translations(cards, loc, translated)
    rescue => e
      Rails.logger.error("[SurveyTranslator] #{loc}: #{e.class}: #{e.message}")
    end
    survey.update!(cards: cards)
  end

  # Translate a single freshly-generated card into the Verto's secondary
  # languages, returning the card with its i18n map populated.
  def translate_card!(card, survey)
    return card unless survey.secondary_locales.any?

    survey.secondary_locales.each do |loc|
      translated = SurveyTranslator.new.call(cards: [ card ], target_locale: loc, source_locale: survey.default_locale)
      card = Survey.merge_card_translations([ card ], loc, translated).first
    rescue => e
      Rails.logger.error("[SurveyTranslator card] #{loc}: #{e.class}: #{e.message}")
    end
    card
  end

  def render_card_html(survey, card)
    existing = Array(survey.cards)
    idx      = existing.size
    total_q  = existing.count { |c| c["type"] != "welcome_card" } +
               (card["type"] != "welcome_card" ? 1 : 0)
    q_idx    = card["type"] != "welcome_card" ? total_q : 0
    render_to_string(
      partial: "surveys/card_row",
      formats: [ :html ],
      locals:  { card: card, idx: idx, q_idx: q_idx, total_q: total_q, default_locale: survey.default_locale }
    )
  end

  def set_survey_including_archived
    @survey = Current.organisation.surveys.find(params[:id])
  end
end
