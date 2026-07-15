class SurveysController < ApplicationController
  include AggregatesSurveyResults
  include ResolvesResultSegments
  layout "fullscreen", only: [ :show, :new ]

  MAX_PDF_BYTES = 10.megabytes

  before_action :require_admin!,       only: [ :destroy, :destroy_forever, :bulk_archive, :bulk_destroy ]
  before_action :set_survey,           only: [ :show, :preview, :publish, :update_settings ]
  before_action :set_survey_including_archived, only: [ :results, :results_compare ]

  helper_method :accessible_common_question_sets

  def index
    @surveys          = Current.organisation.surveys.kept.without_report_text.order(updated_at: :desc).to_a
    @archived_surveys = Current.organisation.surveys.archived.without_report_text.order(deleted_at: :desc).to_a

    # Per-survey response tallies as grouped SQL counts (a few queries total),
    # instead of eager-loading every response's answers JSON and counting in
    # Ruby per card — the cause of the multi-second index ActiveRecord time.
    ids = (@surveys + @archived_surveys).map(&:id)
    @completed_counts           = Response.where(survey_id: ids, status: "completed").group(:survey_id).count
    @responder_counts           = Response.where(survey_id: ids, answered: true).group(:survey_id).count
    @responder_completed_counts = Response.where(survey_id: ids, answered: true, status: "completed").group(:survey_id).count
    render :index, layout: "fullscreen"
  end

  def new
    # The dashboard's Create menu pre-decides quiz mode (its "Quiz" tile links
    # here with ?quiz=1); the wizard carries it through a hidden field.
    @quiz_preset = ActiveModel::Type::Boolean.new.cast(params[:quiz]) || false
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
      result = {
        "title" => theme,
        "description" => nil,
        "theme" => theme,
        "audience_age" => audience_age,
        "key_insight" => nil,
        "cards" => [ { "type" => "welcome_card", "title" => theme, "text" => theme } ] + common_cards
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

    # No name is asked up front — the AI-written title from the generation is
    # the Verto's name, renameable any time in the editor header.
    @survey = Current.organisation.surveys.create!(
      title:        result["title"],
      description:  result["description"],
      theme:        result["theme"].presence || theme,
      audience_age: result["audience_age"].presence || audience_age,
      key_insight:  result["key_insight"].presence || key_insight,
      cards:        DemographicQuestions.append_to(result["cards"]),
      show_results_comparison: show_compare,
      quiz:         quiz,
      brand_palette: palette.presence,
      default_locale: default_locale,
      locales:        locales
    )

    # Remember the palette as the company default so the next Verto inherits it.
    Current.organisation.update(default_brand_palette: palette) if palette.present?

    translate_survey!(@survey)

    # Every new Verto comes pre-populated with imagery (background + card art)
    # so the editor never opens blank; creators can swap or clear any image.
    auto_populate_assets!(@survey)

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

    default_locale = wizard_default_locale
    data    = Base64.strict_encode64(pdf.read)
    result  = PdfQuestionImporter.new.call(pdf_data: data, locale: default_locale)
    cards   = Array(result["cards"])

    return import_pdf_error("We couldn't find any questions in that PDF — try a different file.") if cards.empty?

    payload = wizard_import_payload(result)

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

  # POST /surveys/import_manual
  # Creates a Verto from questions the creator typed or pasted into the
  # wizard's final "Have your own questions?" step — the same pipeline as the
  # PDF import (verbatim wording, best-fit card types, and the review screen
  # when questions break the design rules).
  MAX_MANUAL_CHARS = 20_000

  def import_manual
    text = params[:manual_questions].to_s.strip

    return import_manual_error("Type or paste your questions first.") if text.blank?
    if text.size > MAX_MANUAL_CHARS
      return import_manual_error("That's a lot of text — please keep it under #{MAX_MANUAL_CHARS / 1_000}k characters.")
    end

    result = ManualQuestionImporter.new.call(text: text, locale: wizard_default_locale)
    cards  = Array(result["cards"])

    return import_manual_error("We couldn't find any questions in that text — try one question per line.") if cards.empty?

    payload = wizard_import_payload(result)

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
    Rails.logger.error("[ManualQuestionImporter] #{e.class}: #{e.message}")
    import_manual_error("We couldn't import your questions — #{friendly_generate_error(e)}")
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

  # POST /surveys/import_google_form
  # Creates a Verto from an existing Google Form: fetches the form via the
  # Forms API with the user's OAuth token, maps each question to its
  # best-fitting Verto card type (verbatim), and opens the editor — where the
  # per-card "Optimise" turns them into rule-compliant Verto questions.
  def import_google_form
    return import_google_form_error("Google isn't set up on this server.") unless GoogleOauthService.configured?
    return redirect_to google_connect_path(return_to: google_form_return_to) unless Current.user&.google_connected?

    form_id = GoogleFormsClient.extract_form_id(params[:google_form_url])
    if form_id.blank?
      return import_google_form_error("Paste your Google Form's edit link, e.g. https://docs.google.com/forms/d/…/edit")
    end

    token  = GoogleOauthService.client_for(Current.user).access_token
    form   = GoogleFormsClient.new(token).fetch(form_id)
    result = GoogleFormsImporter.call(form)

    return import_google_form_error("We couldn't find any questions in that form.") if Array(result["cards"]).empty?

    @survey = create_imported_survey!(wizard_import_payload(result), variant: "verbatim")
    redirect_to survey_path(@survey)
  rescue GoogleOauthService::NotConnected, GoogleFormsClient::NotAuthorized
    # Connected before Forms access was added (or token revoked) — reconnect.
    redirect_to google_connect_path(return_to: google_form_return_to)
  rescue GoogleFormsClient::Error => e
    import_google_form_error(e.message)
  rescue => e
    Rails.logger.error("[SurveysController#import_google_form] #{e.class}: #{e.message}")
    import_google_form_error("We couldn't import that Google Form — #{friendly_generate_error(e)}")
  end

  # POST /surveys/create_blank
  # The dashboard's "Create a Form" modal, other option: no AI brief, no
  # import — an empty Verto (just the welcome card and the standard closing
  # demographic questions every creation path adds) that opens straight in
  # the editor for the creator to build card by card.
  def create_blank
    payload = {
      "result"              => { "cards" => [] },
      "verto_name"          => "Untitled Verto",
      "theme"               => "",
      "audience_age"        => "",
      "key_insight"         => "",
      "brand_palette"       => {},
      "default_locale"      => Current.locale,
      "locales"             => [ Current.locale.to_s ],
      "common_question_ids" => []
    }
    @survey = create_imported_survey!(payload, variant: "verbatim")
    redirect_to survey_path(@survey)
  rescue => e
    Rails.logger.error("[SurveysController#create_blank] #{e.class}: #{e.message}")
    redirect_back fallback_location: root_path, allow_other_host: false, alert: "We couldn't create your Verto — #{friendly_generate_error(e)}"
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
      attrs[:cards]                          = Survey.sanitize_cards_images!(payload["cards"])
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

  # On-demand Pexels search for the editor media picker. `context` selects the
  # aspect ratio ("background" → landscape, else portrait card art); `media`
  # selects photos (default) or videos. Returns a uniform `images` array whose
  # items are tagged type:"photo" (carry `url`) or type:"video" (carry `video`
  # + `poster`).
  # POST /surveys/:id/moderate_image
  # Content-safety gate for a creator UPLOAD (a base64 data URL from the media
  # picker). Pexels picks are filtered by query/description; uploads can't be,
  # so the picker calls this once before applying an uploaded image. Returns
  # { ok: true } to allow, { ok: false, reason: } to block.
  def moderate_image
    survey = Current.organisation.surveys.kept.find(params[:id])
    image  = params[:image].to_s

    return render json: { ok: true } unless ImageModerator.configured?
    if image.blank? || !image.start_with?("data:image/")
      return render json: { ok: false, reason: "That doesn't look like an image." }
    end

    verdict = ImageModerator.new.call(data_url: image, audience_age: survey.audience_age)
    if verdict[:safe]
      render json: { ok: true }
    else
      render json: { ok: false, reason: verdict[:reason].presence || "That image isn't PG or age-appropriate for this Verto." }
    end
  rescue ActiveRecord::RecordNotFound
    raise # let it 404 rather than read as "couldn't check"
  rescue => e
    Rails.logger.error("[SurveysController#moderate_image] #{e.class}: #{e.message}")
    render json: { ok: false, reason: "We couldn't check that image — please try again." }, status: :bad_gateway
  end

  def pexels_search
    survey  = Current.organisation.surveys.kept.find(params[:id]) # org-scope / 404 guard
    raw     = params[:q].to_s.strip
    context = params[:context].to_s == "background" ? :background : :card

    return render json: { images: [] } if raw.blank?
    unless PexelsClient.configured?
      return render json: { images: [], error: "search_unavailable" }
    end

    # Keep results PG + age-appropriate to this Verto: scrub the search terms,
    # and (below) drop any result whose description isn't safe.
    age   = AssetPopulator.age_buckets(survey.audience_age)
    query = ContentSafety.scrub_query(raw, age)
    return render json: { images: [], error: "search_blocked" } if query.blank?

    orientation = PexelsClient::ORIENTATION_FOR[context]
    images =
      if params[:media].to_s == "videos"
        pexels_video_results(query, orientation, age)
      else
        pexels_photo_results(query, orientation, context, age)
      end
    render json: { images: images }
  rescue => e
    Rails.logger.error("[SurveysController#pexels_search] #{e.class}: #{e.message}")
    render json: { images: [], error: "search_failed" }, status: :bad_gateway
  end

  def publish
    @survey.update!(
      publish_token: @survey.publish_token || SecureRandom.urlsafe_base64(18),
      published_at:  @survey.published_at  || Time.current
    )
    redirect_to survey_path(@survey)
  end

  # POST /surveys/:id/duplicate
  # Copies a Verto — draft or live — into a brand-new draft under the same
  # organisation, then opens it in the editor. See Survey#duplicate! for what
  # is and isn't carried over.
  def duplicate
    survey = Current.organisation.surveys.kept.find(params[:id])
    redirect_to survey_path(survey.duplicate!)
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
    if params.key?(:logic)
      attrs[:logic] = ActiveModel::Type::Boolean.new.cast(params[:logic])
    end
    if params.key?(:render_mode)
      attrs[:render_mode] = Survey.normalize_render_mode(params[:render_mode])
    end
    if params.key?(:tokenisation_enabled)
      attrs[:tokenisation_enabled] = ActiveModel::Type::Boolean.new.cast(params[:tokenisation_enabled])
    end
    if params.key?(:token_types)
      attrs[:token_types] = Survey.sanitize_token_types(JSON.parse(params[:token_types]))
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

    # The custom link shares the /play/:token namespace with publish_token and
    # every share/region token (PlayerController#load_survey_and_share), so an
    # unavailable slug is rejected rather than silently overwriting/colliding
    # with something else — surfaced back to the panel via a query param since
    # this form (like its siblings) is a plain redirect, not a fetch call.
    slug_taken = false
    if params.key?(:slug)
      desired = Survey.normalize_slug(params[:slug])
      if desired.blank?
        attrs[:slug] = nil
      elsif Survey.slug_taken?(desired, excluding_id: @survey.id)
        slug_taken = true
      else
        attrs[:slug] = desired
      end
    end

    @survey.update!(attrs) if attrs.any?
    redirect_to survey_path(@survey, slug_error: (slug_taken ? "taken" : nil), panel: "publish")
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

  # JSON for the full-screen "Compare" view: every segment's own aggregate
  # breakdown in one payload, so switching which segments are shown happens
  # client-side (no reload per toggle, unlike the single-segment `results`
  # view above).
  def results_compare
    _base, segments, = resolve_result_segments(@survey, nil)
    cards = Array(@survey.cards)

    render json: {
      ok: true,
      cards: cards.map.with_index { |card, idx|
        { index: idx, type: card["type"], text: card["text"], options: card["options"],
          demographic: card["demographic"].present? }
      },
      segments: segments.map { |seg| seg.slice(:id, :label, :count) },
      aggregates: segments.each_with_object({}) { |seg, acc| acc[seg[:id]] = aggregate_results(cards, seg[:scope]) }
    }
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
      "options"     => new_options.presence || card["options"],
      # Refresh the Why "outcome" line to match the rewrite; competency/condition
      # ride along from the original card untouched.
      "outcome"     => optimised["outcome"].to_s.presence || card["outcome"]
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
    # Stamp a stable cid now so the freshly inserted card is a valid
    # answer-branching target (and carries its identity) before the first save.
    card["cid"] = card["cid"].to_s.strip.presence || "c_#{SecureRandom.hex(3)}" if card.is_a?(Hash)

    html = render_card_html(survey, card)
    render json: { ok: true, html: html }
  rescue => e
    Rails.logger.error("[SurveysController#render_card] #{e.class}: #{e.message}")
    render json: { ok: false, error: e.message }, status: :unprocessable_entity
  end

  private

  def pexels_photo_results(query, orientation, context, age = [])
    PexelsClient.new.search(query: query, orientation: orientation, per_page: 24)
      .select { |p| ContentSafety.safe?(p["alt"], age) }
      .map do |p|
      {
        id:               p["id"],
        type:             "photo",
        url:              PexelsClient.url_for(p, context),
        thumb:            (p["src"] || {})["tiny"],
        photographer:     p["photographer"],
        photographer_url: p["photographer_url"],
        alt:              p["alt"]
      }
    end
  end

  def pexels_video_results(query, orientation, age = [])
    PexelsClient.new.search_videos(query: query, orientation: orientation, per_page: 24)
      .select { |v| ContentSafety.safe?(v["url"], age) }
      .filter_map do |v|
      url = PexelsClient.video_file_url(v)
      next unless url
      credit = PexelsClient.video_credit(v)
      poster = PexelsClient.video_poster(v)
      {
        id:               v["id"],
        type:             "video",
        video:            url,
        poster:           poster,
        thumb:            poster,
        photographer:     credit["name"],
        photographer_url: credit["url"]
      }
    end
  end

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
  # Primary locale chosen in the wizard (used by the PDF importer's AI call).
  def wizard_default_locale
    locales = SupportedLocales.sanitize_list(params[:locales], fallback: [ Current.locale.to_s ])
    SupportedLocales.coerce(params[:default_locale].presence || locales.first)
  end

  # Shared import payload built from the wizard form fields — used by both the
  # PDF and Google Forms import paths so they can't drift.
  def wizard_import_payload(result)
    default_locale = wizard_default_locale
    locales        = ([ default_locale ] + SupportedLocales.sanitize_list(params[:locales], fallback: [ Current.locale.to_s ])).uniq

    {
      "result"              => result,
      "verto_name"          => params[:verto_name].to_s.strip,
      "theme"               => params[:theme].to_s,
      "audience_age"        => params[:audience_age].to_s,
      "key_insight"         => params[:key_insight].to_s,
      "brand_palette"       => BrandPalette.sanitize(params[:brand_palette]),
      "default_locale"      => default_locale,
      "locales"             => locales,
      "common_question_ids" => Array(params[:common_question_ids]),
      # Quiz mode is chosen once, up front (Create menu's Quiz tile / Card 1's
      # hidden field) and must survive whichever door the creator ends up
      # using — AI generation, PDF import, Google Form import, or pasted
      # questions — since these import buttons submit the SAME wizard <form>.
      "quiz"                => ActiveModel::Type::Boolean.new.cast(params[:quiz]) || false
    }
  end

  def create_imported_survey!(payload, variant:)
    result = payload["result"]
    cards  = Array(result["cards"]).map do |c|
      card = c.except("compliant", "issue", "original_text")
      card["text"] = c["original_text"] if variant == "verbatim" && c["original_text"].present?
      card
    end

    # Every Verto opens with a welcome card — imports (PDF / Google Forms) carry
    # only questions, so prepend one built from the brief when it's missing.
    unless cards.any? { |c| c["type"].to_s == "welcome_card" }
      cards.unshift({
        "type"  => "welcome_card",
        "title" => payload["verto_name"].presence || result["title"].presence || payload["theme"].presence || "Welcome",
        "text"  => result["description"].presence || payload["theme"].presence
      }.compact)
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
      brand_palette:  payload["brand_palette"].presence,
      default_locale: payload["default_locale"],
      locales:        payload["locales"],
      quiz:           ActiveModel::Type::Boolean.new.cast(payload["quiz"]) || false
    )

    Current.organisation.update(default_brand_palette: payload["brand_palette"]) if payload["brand_palette"].present?
    translate_survey!(survey)
    auto_populate_assets!(survey)
    survey
  end

  # Pre-populate a freshly created Verto's imagery. Best-effort: a populator
  # failure (e.g. a transient Pexels issue) must never block Verto creation.
  def auto_populate_assets!(survey)
    AssetPopulator.new(survey).populate!
  rescue => e
    Rails.logger.error("[AssetPopulator] #{e.class}: #{e.message}")
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
  # sets, plus any kept set shared into a Collective Impact partnership it's an
  # active member of. Own sets come first; shared sets keep their owning org
  # so the wizard can label provenance. Used by both the wizard and the
  # resolve above, so the picker and the authorization can't drift apart.
  def accessible_common_question_sets
    own = Current.organisation.common_question_sets.kept
                  .includes(:common_questions).order(:name).to_a

    partnership_ids = Current.organisation.member_partnerships
                     .where(partnership_memberships: { status: "active" }).pluck(:id)
    shared = if partnership_ids.any?
      set_ids = PartnershipCommonQuestionSet.where(partnership_id: partnership_ids).pluck(:common_question_set_id)
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
  alias_method :import_manual_error, :import_pdf_error

  # Google Form import is reachable from both the wizard's Card 1 and the
  # dashboard's own "Create a Form" modal — send an error back to wherever the
  # request actually came from (via the Referer) rather than always landing on
  # the wizard, so a dashboard-started import fails back into the dashboard.
  # flash[:alert] is the message itself (the wizard already renders it);
  # reopen_google_form_modal is a dashboard-only marker so the modal reopens
  # with that same message instead of it vanishing as a page-level flash.
  def import_google_form_error(message)
    flash[:alert] = message
    flash[:reopen_google_form_modal] = true if params[:source] == "dashboard"
    redirect_back fallback_location: new_survey_path
  end

  # Which page a "Connect Google" detour should return to afterwards — the
  # dashboard modal marks its form with source=dashboard; the wizard's import
  # box (no such field) keeps the existing "import" target.
  def google_form_return_to
    params[:source] == "dashboard" ? "dashboard_import" : "import"
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

  def set_survey_including_archived
    @survey = Current.organisation.surveys.find(params[:id])
  end
end
