class SurveysController < ApplicationController
  include AggregatesSurveyResults
  include ResolvesResultSegments
  layout "fullscreen", only: [ :show, :new ]

  MAX_PDF_BYTES = 10.megabytes

  before_action :require_admin!,       only: [ :destroy, :destroy_forever, :bulk_archive, :bulk_destroy ]
  before_action :set_survey,           only: [ :show, :preview, :publish, :update_settings ]
  before_action :set_survey_including_archived, only: [ :results ]

  helper_method :accessible_common_question_sets

  def index
    kept_surveys = Current.organisation.surveys.kept.without_report_text.includes(:responses).order(updated_at: :desc)
    @surveys          = kept_surveys
    @archived_surveys = Current.organisation.surveys.archived.without_report_text.includes(:responses).order(deleted_at: :desc)
    @total_responses  = Current.organisation.surveys.kept.joins(:responses).count
    render :index, layout: "fullscreen"
  end

  def new
  end

  def show
    render :show
  end

  # GET /surveys/:id/preview
  # Step through the Verto exactly as a respondent will see it. Renders the
  # player with its recording endpoints disabled, so nothing is ever saved —
  # and unlike the public /play link it also works for unpublished drafts.
  def preview
    @preview    = true
    @chromeless = true
    @display_locale = @survey.display_locale_for(params[:lang], Current.locale)
    render "player/show", layout: "fullscreen"
  end

  def generate
    theme        = params[:theme].to_s.strip
    audience_age = params[:audience_age].to_s.strip
    key_insight  = params[:key_insight].to_s.strip
    notes        = params[:notes].to_s.strip
    show_compare = ActiveModel::Type::Boolean.new.cast(params[:show_results_comparison])
    quiz         = ActiveModel::Type::Boolean.new.cast(params[:quiz]) || false
    palette      = BrandPalette.sanitize(params[:brand_palette])

    # Languages this Verto is built in. The primary (default_locale) is the
    # generation source and the canonical language answers align against; the
    # rest are translated from it.
    locales        = SupportedLocales.sanitize_list(params[:locales], fallback: [ Current.locale.to_s ])
    default_locale = SupportedLocales.coerce(params[:default_locale].presence || locales.first)
    locales        = ([ default_locale ] + locales).uniq

    if theme.empty? || audience_age.empty?
      flash.now[:alert] = "Tell us what your Verto's about and who's answering — those are required."
      return render :new, status: :unprocessable_entity
    end

    common_cards = resolve_common_cards(params[:common_question_ids])

    # The learning goal and Common Questions are an or/and: a key insight
    # drives AI generation, picked Common Questions can ride along — and a
    # deck of ONLY Common Questions skips generation entirely.
    if key_insight.empty? && common_cards.empty?
      flash.now[:alert] = "Add what you want to learn, or pick some Common Questions — one of the two is required."
      return render :new, status: :unprocessable_entity
    end

    if key_insight.empty?
      verto_name = params[:verto_name].to_s.strip
      result = {
        "title" => verto_name.presence || theme,
        "description" => nil,
        "theme" => theme,
        "audience_age" => audience_age,
        "key_insight" => nil,
        "cards" => [ { "type" => "welcome_card", "title" => verto_name.presence || theme, "text" => theme } ] + common_cards
      }
    else
      result = SurveyGenerator.new.call(
        theme: theme,
        audience_age: audience_age,
        key_insight: key_insight,
        notes: notes,
        locale: default_locale,
        common_cards: common_cards,
        quiz: quiz
      )
    end

    @survey = Current.organisation.surveys.create!(
      title:        params[:verto_name].to_s.strip.presence || result["title"],
      description:  result["description"],
      theme:        result["theme"].presence || theme,
      audience_age: result["audience_age"].presence || audience_age,
      key_insight:  result["key_insight"].presence || key_insight,
      cards:        DemographicQuestions.append_to(result["cards"]),
      show_results_comparison: show_compare,
      quiz:         quiz,
      ask_region:   ActiveModel::Type::Boolean.new.cast(params[:ask_region]) || false,
      brand_palette: palette.presence,
      default_locale: default_locale,
      locales:        locales
    )

    # Remember the palette as the company default so the next Verto inherits it.
    Current.organisation.update(default_brand_palette: palette) if palette.present?

    create_region_links(@survey, params[:region_tags])

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

  # POST /surveys/import_pdf
  # Creates a Verto from a user's prewritten questions in an uploaded PDF,
  # auto-assigning each question its best-fitting card type, then opens the editor.
  def import_pdf
    pdf = params[:pdf]

    unless pdf.respond_to?(:read) && pdf.content_type == "application/pdf"
      return import_pdf_error("Please choose a PDF file to import.")
    end
    if pdf.size > MAX_PDF_BYTES
      return import_pdf_error("That PDF is too large — please keep it under #{MAX_PDF_BYTES / 1.megabyte}MB.")
    end

    palette        = BrandPalette.sanitize(params[:brand_palette])
    locales        = SupportedLocales.sanitize_list(params[:locales], fallback: [ Current.locale.to_s ])
    default_locale = SupportedLocales.coerce(params[:default_locale].presence || locales.first)
    locales        = ([ default_locale ] + locales).uniq

    data   = Base64.strict_encode64(pdf.read)
    result = PdfQuestionImporter.new.call(pdf_data: data, locale: default_locale)
    cards  = Array(result["cards"])

    return import_pdf_error("We couldn't find any questions in that PDF — try a different file.") if cards.empty?

    payload = {
      "result"         => result,
      "verto_name"     => params[:verto_name].to_s.strip,
      "theme"          => params[:theme].to_s,
      "audience_age"   => params[:audience_age].to_s,
      "key_insight"    => params[:key_insight].to_s,
      "brand_palette"  => palette,
      "default_locale" => default_locale,
      "locales"        => locales,
      "common_question_ids" => Array(params[:common_question_ids]),
      "ask_region"     => ActiveModel::Type::Boolean.new.cast(params[:ask_region]) || false,
      "region_tags"    => Array(params[:region_tags]).map { |t| { "country_code" => t[:country_code].to_s, "label" => t[:label].to_s } }
    }

    # Questions that don't fit Verto's design rules pause the import: the
    # creator reviews their wording next to Verto's optimised version and
    # decides. Fully compliant decks go straight to the editor as before.
    flagged = cards.select { |c| c["compliant"] == false }
    if flagged.any?
      @import_payload = self.class.import_verifier.generate(payload)
      @import_cards   = cards
      @flagged_count  = flagged.size
      return render :import_review, layout: "fullscreen"
    end

    @survey = create_imported_survey!(payload, variant: "verbatim")

    redirect_to survey_path(@survey)
  rescue => e
    Rails.logger.error("[PdfQuestionImporter] #{e.class}: #{e.message}")
    import_pdf_error("We couldn't import your PDF — #{friendly_generate_error(e)}")
  end

  # POST /surveys/finalize_import
  # Second leg of a PDF import whose questions didn't all meet Verto's design
  # rules: the creator chose either their original wording or Verto's
  # optimised version. The pending import travels as a signed blob, so the
  # cards can't be tampered with between the two requests.
  def finalize_import
    payload = self.class.import_verifier.verified(params[:payload].to_s)
    return redirect_to new_survey_path, alert: "That import session expired — please upload the PDF again." unless payload

    variant = params[:variant] == "optimised" ? "optimised" : "verbatim"
    @survey = create_imported_survey!(payload, variant: variant)
    redirect_to survey_path(@survey)
  rescue => e
    Rails.logger.error("[SurveysController#finalize_import] #{e.class}: #{e.message}")
    redirect_to new_survey_path, alert: "We couldn't finish the import — #{friendly_generate_error(e)}"
  end

  def update
    survey = Current.organisation.surveys.kept.find(params[:id])
    if survey.published?
      return render json: { ok: false, error: "This Verto is live — editing is locked." }, status: :locked
    end
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

  # Settings forms each post the one field they own — only touch what's sent.
  def update_settings
    attrs = {}
    if params.key?(:show_results_comparison)
      attrs[:show_results_comparison] = ActiveModel::Type::Boolean.new.cast(params[:show_results_comparison])
    end
    if params.key?(:quiz)
      attrs[:quiz] = ActiveModel::Type::Boolean.new.cast(params[:quiz])
    end
    if params.key?(:ask_region)
      attrs[:ask_region] = ActiveModel::Type::Boolean.new.cast(params[:ask_region])
    end
    if params.key?(:compare_note)
      attrs[:compare_note] = params[:compare_note].to_s.strip.first(160).presence
    end
    if params.key?(:thankyou_title)
      attrs[:thankyou_title] = params[:thankyou_title].to_s.strip.first(80).presence
    end
    if params.key?(:thankyou_body)
      attrs[:thankyou_body] = params[:thankyou_body].to_s.strip.first(400).presence
    end
    if params.key?(:forward_url)
      attrs[:forward_url] = Survey.sanitize_forward_url(params[:forward_url])
    end
    if params.key?(:consent_text)
      attrs[:consent_text] = params[:consent_text].to_s.strip.first(2000).presence
    end
    @survey.update!(attrs) if attrs.any?
    redirect_to survey_path(@survey)
  end

  def shuffle_assets
    survey = Current.organisation.surveys.kept.find(params[:id])
    if survey.published?
      return redirect_to survey_path(survey), alert: "This Verto is live — editing is locked."
    end
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
    if survey.published?
      return render json: { ok: false, error: "This Verto is live — editing is locked." }, status: :locked
    end

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
    render json: { ok: false, error: friendly_generate_error(e) }, status: :unprocessable_entity
  end

  # POST /surveys/:id/optimise_card
  # AI-rewrite ONE flagged card so it satisfies the Rules of the Game, fixing the
  # editor-listed issues while keeping the answer type and intent. Returns the
  # optimised card JSON + its rendered editor partial, so the editor can swap it
  # in place and the traffic light turns green.
  def optimise_card
    @survey = survey = Current.organisation.surveys.kept.find(params[:id])
    if survey.published?
      return render json: { ok: false, error: "This Verto is live — editing is locked." }, status: :locked
    end
    body = JSON.parse(request.body.read)
    card = body["card"].is_a?(Hash) ? body["card"] : {}
    return render json: { ok: false, error: "No card to optimise." }, status: :unprocessable_entity if card["type"].blank?

    optimised = CardOptimiser.new.call(
      card:         card,
      issues:       body["issues"],
      theme:        survey.theme,
      audience_age: survey.audience_age,
      key_insight:  survey.key_insight,
      locale:       survey.default_locale
    )

    # Keep the card's structural fields; take the improved wording/options. Drop
    # the now-stale per-language translations and re-translate from the new
    # primary so every language stays aligned.
    new_options = Array(optimised["options"]).map { |o| o.to_s.strip }.reject(&:blank?)
    merged = card.merge(
      "type"        => optimised["type"],
      "text"        => optimised["text"].to_s.presence || card["text"],
      "description" => optimised["description"].to_s.presence,
      "options"     => new_options.presence || card["options"]
    ).except("i18n").compact
    if merged["type"] == "tap_card" && merged["option_images"].present?
      merged["option_images"] = Array(merged["option_images"]).first(Array(merged["options"]).size)
    end
    merged = translate_card!(merged, survey)

    html = render_card_html(survey, merged, idx: body["index"].to_i)
    render json: { ok: true, card: merged, html: html }
  rescue => e
    Rails.logger.error("[SurveysController#optimise_card] #{e.class}: #{e.message}")
    render json: { ok: false, error: friendly_generate_error(e) }, status: :unprocessable_entity
  end

  # POST /surveys/:id/render_card
  # Renders the HTML partial for a given card JSON (used by "Start from Blank" flow).
  def render_card
    survey = Current.organisation.surveys.kept.find(params[:id])
    if survey.published?
      return render json: { ok: false, error: "This Verto is live — editing is locked." }, status: :locked
    end
    card   = JSON.parse(request.body.read)

    html = render_card_html(survey, card)
    render json: { ok: true, html: html }
  rescue => e
    Rails.logger.error("[SurveysController#render_card] #{e.class}: #{e.message}")
    render json: { ok: false, error: e.message }, status: :unprocessable_entity
  end

  private

  def set_survey
    @survey = Current.organisation.surveys.kept.without_report_text.find(params[:id])
  end

  def self.import_verifier
    Rails.application.message_verifier(:pdf_import)
  end

  # Builds the Verto from a pending-import payload (the hash assembled in
  # import_pdf). variant "verbatim" restores each question's original PDF
  # wording; "optimised" keeps Verto's rule-compliant rewrite. Common cards,
  # the demographic tail, region tags and translation all happen here so both
  # the straight-through and the reviewed path create identical structures.
  def create_imported_survey!(payload, variant:)
    result = payload["result"]
    cards  = Array(result["cards"]).map do |c|
      card = c.except("compliant", "issue", "original_text")
      card["text"] = c["original_text"] if variant == "verbatim" && c["original_text"].present?
      card
    end

    cards += resolve_common_cards(payload["common_question_ids"])
    cards  = DemographicQuestions.append_to(cards)

    survey = Current.organisation.surveys.create!(
      title:          payload["verto_name"].presence || result["title"].presence || "Imported Verto",
      description:    result["description"],
      theme:          payload["theme"].presence,
      audience_age:   payload["audience_age"].presence,
      key_insight:    payload["key_insight"].presence,
      cards:          cards,
      ask_region:     payload["ask_region"] == true,
      brand_palette:  payload["brand_palette"].presence,
      default_locale: payload["default_locale"],
      locales:        payload["locales"]
    )

    Current.organisation.update(default_brand_palette: payload["brand_palette"]) if payload["brand_palette"].present?
    create_region_links(survey, payload["region_tags"])
    translate_survey!(survey)
    survey
  end

  # Region tags picked in the creation wizard: [{ country_code:, label: }, …].
  # Invalid or duplicate entries are skipped silently — tags are managed (and
  # visible) in the editor's publish panel right after creation.
  def create_region_links(survey, tags_param)
    Array(tags_param).each do |tag|
      survey.survey_region_links.create(
        country_code: tag[:country_code] || tag["country_code"],
        label:        (tag[:label] || tag["label"]).to_s.strip.presence
      )
    end
  end

  # Snapshot the SELECTED Common Questions into Verto-card hashes. Takes
  # individual question ids (the wizard lets creators pick questions, not just
  # whole sets) and only honours ids belonging to a set this org may use —
  # so a partner can't splice in questions from a set not shared with them.
  # Each card carries common_question_id + set_id so cross-Verto results
  # aggregation can cluster answers by question identity.
  def resolve_common_cards(ids_param)
    ids = Array(ids_param).map(&:to_i).reject(&:zero?)
    return [] if ids.empty?
    accessible_ids = accessible_common_question_sets.map(&:id)
    CommonQuestion.where(id: ids, common_question_set_id: accessible_ids)
                  .order(:common_question_set_id, :position)
                  .map(&:to_card)
  end

  # Common Question sets the current org may attach to a Verto: its own kept
  # sets, plus any kept set shared into a Collective Impact alliance it's an
  # active member of. Own sets come first; shared sets keep their owning org
  # so the wizard can label provenance. Used by both the wizard and the
  # resolve above, so the picker and the authorization can't drift apart.
  def accessible_common_question_sets
    own = Current.organisation.common_question_sets.kept
                  .includes(:common_questions).order(:name).to_a

    alliance_ids = Current.organisation.member_alliances
                     .where(alliance_memberships: { status: "active" }).pluck(:id)
    shared = if alliance_ids.any?
      set_ids = AllianceCommonQuestionSet.where(alliance_id: alliance_ids).pluck(:common_question_set_id)
      CommonQuestionSet.kept.where(id: set_ids)
                       .where.not(organisation_id: Current.organisation.id)
                       .includes(:common_questions, :organisation).order(:name).to_a
    else
      []
    end

    own + shared
  end

  # Re-render the wizard with an error. `import_pdf` isn't covered by the
  # class-level `layout "fullscreen", only: [:show, :new]` (which keys on the
  # action name), so the layout is set explicitly here.
  def import_pdf_error(message)
    flash.now[:alert] = message
    render :new, layout: "fullscreen", status: :unprocessable_entity
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

  # Renders a card's editor partial. With no `idx` the card is treated as a new
  # one appended to the deck (the add-question flow); with an explicit `idx` it's
  # rendered in place at that position (the optimise flow), so its card number
  # and progress match where it already sits.
  def render_card_html(survey, card, idx: nil)
    # The card_row partial (and its children) read @survey — e.g. for the
    # "recommended for this card" images. generate_card / render_card don't go
    # through set_survey, so make sure it's set or those renders 500 on nil.
    @survey ||= survey
    existing = Array(survey.cards)
    if idx
      total_q = existing.count { |c| c["type"] != "welcome_card" }
      q_idx   = existing.first(idx + 1).count { |c| c["type"] != "welcome_card" }
    else
      idx     = existing.size
      total_q = existing.count { |c| c["type"] != "welcome_card" } +
                (card["type"] != "welcome_card" ? 1 : 0)
      q_idx   = card["type"] != "welcome_card" ? total_q : 0
    end
    render_to_string(
      partial: "surveys/card_row",
      formats: [ :html ],
      locals:  { card: card, idx: idx, q_idx: q_idx, total_q: total_q,
                 default_locale: survey.default_locale, quiz: survey.quiz? }
    )
  end

  def set_survey_including_archived
    @survey = Current.organisation.surveys.find(params[:id])
  end
end
