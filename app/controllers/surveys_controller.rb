class SurveysController < ApplicationController
  include AggregatesSurveyResults
  include ResolvesResultSegments
  include RendersCardHtml
  include ThrottlesAiSpend
  layout "fullscreen", only: [ :show, :new ]

  # Spend guards (P0-4). Three tiers, because the cost per request differs by
  # two orders of magnitude:
  #
  #   deck      — each one enqueues a job that makes many Claude calls
  #               (generation, then one translation call per secondary locale,
  #               then asset population). The expensive tier.
  #   card      — one Claude call per request.
  #   stock     — Pexels rather than Anthropic, so no money changes hands, but
  #               it's still an external quota worth not burning.
  #
  # Limits are per user per hour and set well above real editing behaviour;
  # they exist to stop a retry loop or a scripted client, not to ration work.
  throttle_ai to: 20,  within: 1.hour, name: "ai-deck", respond: :html,
              only: %i[ generate import_pdf import_manual import_google_form
                        finalize_import create_blank update_audience_country ]
  throttle_ai to: 20,  within: 1.hour, name: "ai-deck-json", respond: :json,
              only: %i[ resume_import generate_flow ]
  throttle_ai to: 120, within: 1.hour, name: "ai-card", respond: :json,
              only: %i[ generate_card optimise_card moderate_image ]
  throttle_ai to: 60,  within: 1.hour, name: "stock-media", respond: :json,
              only: %i[ pexels_search ]
  throttle_ai to: 60,  within: 1.hour, name: "stock-shuffle", respond: :html,
              only: %i[ shuffle_assets ]

  # The organisation-wide daily ceiling, which is the number that shows up on
  # the Anthropic invoice. Only the Claude endpoints count against it —
  # pexels_search and shuffle_assets are rate-limited above but cost nothing.
  cap_ai_spend respond: :html,
               only: %i[ generate import_pdf import_manual import_google_form
                         finalize_import create_blank update_audience_country ]
  cap_ai_spend respond: :json,
               only: %i[ resume_import generate_flow generate_card optimise_card
                         moderate_image ]

  MAX_PDF_BYTES = 10.megabytes

  # Shown for moderate_image when we genuinely couldn't get a verdict (API
  # error, or an ambiguous Claude response even after retry) — never implies
  # the image was actually judged unsafe.
  def could_not_verify_image_message = t("flash.surveys.image_unverified")

  # Structural edits are refused while a Verto is live, and stay refused once it
  # has responses even after being unpublished — answers are keyed by card
  # index, so a deck change would misalign what's already stored. See
  # Survey#editing_locked?.
  # Deliberately a method, not a constant. `t` isn't available in a class body,
  # and a constant would resolve once at boot and pin every creator to whatever
  # locale happened to be active then — the exact thing P2-2 is undoing.
  def editing_locked_message = t("flash.surveys.editing_locked")

  # update_settings was the ONLY content endpoint with no lock at all, which is
  # how a consent gate could be bolted onto a Verto people had already answered.
  # A blanket guard would be wrong — most of what it handles is presentation and
  # distribution (thank-you copy, the off-site link, response comparison, the
  # custom slug, branch end screens), and a creator legitimately changes those
  # for the life of a Verto. These are the fields that can't move once it's in
  # use: consent, because consent_text_snapshot on earlier responses would no
  # longer match what those people actually saw and agreed to; and the scoring
  # switches, because flipping them silently rewrites results respondents have
  # already been shown.
  #
  # `logic` and `render_mode` are deliberately NOT here: they change which cards
  # a respondent is routed through and how cards are presented, not what anyone
  # agreed to and not how a stored answer scores.
  #
  # `leaderboard_retake_policy` IS here: flipping it silently rewrites standings
  # respondents have already been shown (accumulate→restart collapses a
  # three-run total to one run), exactly like the scoring switches.
  # `leaderboard_enabled` is not — it only shows or hides a board computed at
  # read time.
  SETTINGS_LOCKED_IN_USE = %i[
    consent_text consent_image consent_image_credit consent_image_credit_url
    tokenisation_enabled token_types quiz leaderboard_retake_policy
  ].freeze

  def settings_locked_message = t("flash.surveys.settings_locked")

  before_action :require_admin!,       only: [ :destroy, :destroy_forever, :restore, :bulk_archive, :bulk_destroy ]
  before_action :set_survey,           only: [ :show, :preview, :publish, :unpublish, :enable_test_link, :disable_test_link, :convert_to_test_mode, :update_settings, :update_audience_country, :qr ]
  before_action :set_survey_including_archived, only: [ :results, :results_compare ]

  helper_method :accessible_common_question_sets
  helper_method :date_range_options

  def index
    @surveys          = Current.organisation.surveys.kept.without_report_text.order(updated_at: :desc).to_a
    @archived_surveys = Current.organisation.surveys.archived.without_report_text.order(deleted_at: :desc).to_a

    # Per-survey response tallies as grouped SQL counts (a few queries total),
    # instead of eager-loading every response's answers JSON and counting in
    # Ruby per card — the cause of the multi-second index ActiveRecord time.
    ids = (@surveys + @archived_surveys).map(&:id)
    @completed_counts           = Response.where(survey_id: ids, status: "completed").group(:survey_id).count
    # Raw existence, for the tile's Closed-vs-Draft badge on an unpublished
    # Verto (Survey#closed?) — kept as a grouped count so it costs one query,
    # not one per tile.
    @response_counts            = Response.where(survey_id: ids).group(:survey_id).count
    @responder_counts           = Response.where(survey_id: ids, answered: true).group(:survey_id).count
    @responder_completed_counts = Response.where(survey_id: ids, answered: true, status: "completed").group(:survey_id).count
    # Ask Verto state per tile, as ONE query rather than a CorpusEntry lookup per
    # card. Only Vertos that have actually been offered are in here; everything
    # else has no entry and therefore no badge.
    @ask_states = CorpusEntry.where(survey_id: ids)
                             .to_h { |entry| [ entry.survey_id, entry.creator_state ] }
    render :index, layout: "fullscreen"
  end

  def new
    # The dashboard's Create menu pre-decides quiz mode (its "Quiz" tile links
    # here with ?quiz=1); the wizard carries it through a hidden field.
    @quiz_preset = ActiveModel::Type::Boolean.new.cast(params[:quiz]) || false
  end

  def show
    # The editor hides the global top nav — it gets a "Leave editor" CTA in
    # its brief strip instead (the command palette stays reachable via ⌘K).
    @hide_main_nav = true
    # Unsaved unless this Verto has actually been offered — rendering the panel
    # must not enrol a Verto in the corpus by looking at it.
    @corpus_entry = CorpusEntry.for(@survey)
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
    # Mirrors PlayerController#render_with_chrome_language — the owner's
    # preview should show the same chrome-language behaviour a respondent
    # would actually get, not the platform default regardless of the toggle.
    if @survey.chrome_follows_verto_language?
      I18n.with_locale(@display_locale) { render "player/show", layout: "fullscreen" }
    else
      render "player/show", layout: "fullscreen"
    end
  end

  def generate
    theme        = params[:theme].to_s.strip
    audience_age = params[:audience_age].to_s.strip
    key_insight  = params[:key_insight].to_s.strip
    notes        = params[:notes].to_s.strip
    show_compare = ActiveModel::Type::Boolean.new.cast(params[:show_results_comparison])
    quiz         = ActiveModel::Type::Boolean.new.cast(params[:quiz]) || false
    palette      = BrandPalette.sanitize(params[:brand_palette])
    brand_font   = Survey.sanitize_brand_font(params[:brand_font])
    heading_font = Survey.sanitize_brand_font(params[:brand_font_heading])
    answer_tint  = ActiveModel::Type::Boolean.new.cast(params[:brand_answer_tint]) || false

    # Languages this Verto is built in. The primary (default_locale) is the
    # generation source and the canonical language answers align against; the
    # rest are translated from it.
    locales        = SupportedLocales.sanitize_list(params[:locales], fallback: [ Current.locale.to_s ])
    default_locale = SupportedLocales.coerce(params[:default_locale].presence || locales.first)
    locales        = ([ default_locale ] + locales).uniq

    if theme.empty? || audience_age.empty?
      flash.now[:alert] = t("flash.surveys.brief_required")
      return render :new, status: :unprocessable_entity
    end

    common_cards = resolve_common_cards(params[:common_question_ids])

    # The learning goal and Common Questions are an or/and: a key insight
    # drives AI generation, picked Common Questions can ride along — and a
    # deck of ONLY Common Questions skips generation entirely.
    if key_insight.empty? && common_cards.empty?
      flash.now[:alert] = t("flash.surveys.learning_goal_required")
      return render :new, status: :unprocessable_entity
    end

    # Everything above needs the request: it authorizes the org, validates the
    # form and resolves which Common Questions this account may actually use.
    # Everything below is 30-120s of Claude and Pexels calls, which used to hold
    # one of three Puma threads for the duration — a few concurrent creations
    # exhausted the pool and 502'd the whole app (P0-3). The job takes it from
    # here and the wizard's overlay polls the build.
    build = Current.organisation.verto_builds.create!(
      user: Current.user,
      payload: {
        theme: theme, audience_age: audience_age, key_insight: key_insight,
        notes: notes, quiz: quiz, show_results_comparison: show_compare,
        brand_palette: palette.presence, brand_font: brand_font,
        brand_font_heading: heading_font,
        brand_answer_tint: answer_tint,
        default_locale: default_locale,
        locales: locales, common_cards: common_cards
      }
    )
    BuildVertoJob.perform_later(build.id)

    redirect_to verto_build_path(build)
  rescue => e
    ErrorReporting.report("SurveyGenerator", e)
    flash.now[:alert] = t("flash.surveys.generate_failed", reason: friendly_generate_error(e))
    render :new, status: :unprocessable_entity
  end

  # POST /surveys/import_pdf
  # Creates a Verto from a user's prewritten questions in an uploaded PDF,
  # auto-assigning each question its best-fitting card type, then opens the editor.
  def import_pdf
    pdf = params[:pdf]

    unless pdf.respond_to?(:read) && pdf.content_type == "application/pdf"
      return import_pdf_error(t("flash.surveys.pdf_required"))
    end
    if pdf.size > MAX_PDF_BYTES
      return import_pdf_error(t("flash.surveys.pdf_too_large", limit: MAX_PDF_BYTES / 1.megabyte))
    end

    # The upload is staged on the build rather than base64'd through the queue —
    # a multi-MB string in a JSON column is the pattern that drove the 502s.
    build = enqueue_import("import_pdf") do |b|
      b.source_file.attach(io: pdf.tempfile, filename: pdf.original_filename, content_type: pdf.content_type)
    end

    redirect_to verto_build_path(build)
  rescue => e
    ErrorReporting.report("PdfQuestionImporter", e)
    import_pdf_error(t("flash.surveys.pdf_import_failed", reason: friendly_generate_error(e)))
  end

  # POST /surveys/import_manual
  # Creates a Verto from questions the creator typed or pasted into the
  # wizard's final "Have your own questions?" step — the same pipeline as the
  # PDF import (verbatim wording, best-fit card types, and the review screen
  # when questions break the design rules).
  MAX_MANUAL_CHARS = 20_000

  def import_manual
    text = params[:manual_questions].to_s.strip

    return import_manual_error(t("flash.surveys.manual_questions_required")) if text.blank?
    if text.size > MAX_MANUAL_CHARS
      return import_manual_error(t("flash.surveys.manual_questions_too_long", limit: MAX_MANUAL_CHARS / 1_000))
    end

    redirect_to verto_build_path(enqueue_import("import_manual", "text" => text))
  rescue => e
    ErrorReporting.report("ManualQuestionImporter", e)
    import_manual_error(t("flash.surveys.manual_import_failed", reason: friendly_generate_error(e)))
  end

  # GET /verto_builds/:id/import
  # Second leg of every import: the slow read has finished in the background and
  # its questions are on the build. What happens now needs the creator, which is
  # why the job stopped here — questions that break Verto's design rules pause
  # at the review screen so they can choose their wording or Verto's, and a
  # clean import goes straight to the editor.
  def resume_import
    build = Current.organisation.verto_builds.find(params[:id])
    return redirect_to new_survey_path, alert: t("flash.surveys.import_unavailable") unless build.succeeded? && build.result

    payload = build.payload
    cards   = Array(build.result["cards"])
    flagged = cards.select { |c| c["compliant"] == false }

    if flagged.any?
      @import_payload = self.class.import_verifier.generate(payload)
      @import_cards   = cards
      @flagged_count  = flagged.size
      return render :import_review, layout: "fullscreen"
    end

    @survey = create_imported_survey!(payload, variant: "verbatim")
    redirect_to survey_path(@survey)
  rescue ActiveRecord::RecordNotFound
    raise # another org's build is a 404, not a redirect — same as every other survey path
  rescue => e
    ErrorReporting.report("SurveysController#resume_import", e)
    redirect_to new_survey_path, alert: t("flash.surveys.import_finish_failed", reason: friendly_generate_error(e))
  end

  # POST /surveys/finalize_import
  # Second leg of a PDF import whose questions didn't all meet Verto's design
  # rules: the creator chose either their original wording or Verto's
  # optimised version. The pending import travels as a signed blob, so the
  # cards can't be tampered with between the two requests.
  def finalize_import
    payload = self.class.import_verifier.verified(params[:payload].to_s)
    return redirect_to new_survey_path, alert: t("flash.surveys.import_session_expired") unless payload

    variant = params[:variant] == "optimised" ? "optimised" : "verbatim"
    @survey = create_imported_survey!(payload, variant: variant)
    redirect_to survey_path(@survey)
  rescue => e
    ErrorReporting.report("SurveysController#finalize_import", e)
    redirect_to new_survey_path, alert: t("flash.surveys.import_finish_failed", reason: friendly_generate_error(e))
  end

  # POST /surveys/import_google_form
  # Creates a Verto from an existing Google Form: fetches the form via the
  # Forms API with the user's OAuth token, maps each question to its
  # best-fitting Verto card type (verbatim), and opens the editor — where the
  # per-card "Optimise" turns them into rule-compliant Verto questions.
  def import_google_form
    return import_google_form_error(t("flash.surveys.google_not_configured")) unless GoogleOauthService.configured?
    return redirect_to google_connect_path(return_to: google_form_return_to) unless Current.user&.google_connected?

    form_id = GoogleFormsClient.extract_form_id(params[:google_form_url])
    if form_id.blank?
      return import_google_form_error(t("flash.surveys.google_form_url_required"))
    end

    # Check the connection here, while we can still redirect the creator into
    # the OAuth flow — the job can only report a failure after the fact.
    GoogleOauthService.client_for(Current.user)

    redirect_to verto_build_path(enqueue_import("import_google_form", "form_id" => form_id))
  rescue GoogleOauthService::NotConnected, GoogleFormsClient::NotAuthorized
    # Connected before Forms access was added (or token revoked) — reconnect.
    redirect_to google_connect_path(return_to: google_form_return_to)
  rescue GoogleFormsClient::Error => e
    import_google_form_error(e.message)
  rescue => e
    ErrorReporting.report("SurveysController#import_google_form", e)
    import_google_form_error(t("flash.surveys.google_form_import_failed", reason: friendly_generate_error(e)))
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
    ErrorReporting.report("SurveysController#create_blank", e)
    redirect_back fallback_location: root_path, allow_other_host: false, alert: t("flash.surveys.create_blank_failed", reason: friendly_generate_error(e))
  end

  def update
    survey = Current.organisation.surveys.kept.find(params[:id])
    if survey.editing_locked?
      return render json: { ok: false, error: editing_locked_message }, status: :locked
    end
    payload = JSON.parse(request.body.read)
    warnings = []

    # Only touch the attributes present in the payload, so the brand-colour
    # PATCH (which sends just `brand_palette`) doesn't wipe title/cards, and the
    # editor autosave (title/description/cards) doesn't touch the palette.
    attrs = {}
    # A blank title is dropped, not saved: the dashboard tile calls a Verto by
    # its title first, so an empty one leaves it with nothing to call itself.
    # The editor guards this too, but a client-side guard that has already
    # failed once is not something to leave as the only one.
    attrs[:title]       = payload["title"].to_s.strip if payload.key?("title") && payload["title"].to_s.strip.present?
    attrs[:description] = payload["description"] if payload.key?("description")
    attrs[:flows]       = Survey.sanitize_flows(payload["flows"]) if payload.key?("flows")
    if payload.key?("cards")
      attrs[:cards] = Survey.sanitize_cards_images!(payload["cards"], warnings: warnings)
      # First-class flows compile down to the per-card `next` pointers the
      # player resolves (see FlowCompiler). Run on every save so the STORED
      # deck can never disagree with the stored flows, whatever the client
      # sent — the editor's client-side compile is only a preview of this.
      flows_now = attrs.key?(:flows) ? attrs[:flows] : survey.flows_list
      Survey.reconcile_flows!(attrs[:cards], flows_now)
      FlowCompiler.compile!(attrs[:cards], flows_now)
      attrs[:results_summary]                = nil
      attrs[:results_summary_response_count] = nil
      # Anything that left the deck goes to the bin, so it can be restored after
      # a reload — the one thing in-session undo can't survive. Computed from the
      # SAVED deck rather than from a client signal, so a delete is caught however
      # it happened (the card row's button, a flow dissolve, a bulk edit).
      attrs[:deleted_cards] =
        Survey.record_deleted_cards(survey.cards, attrs[:cards], survey.deleted_cards)
    elsif attrs.key?(:flows)
      # Flows changed without cards (the editor always sends both, but the
      # invariant shouldn't depend on that): recompile the stored deck so
      # member chains and exits stay consistent with the new flows.
      cards = JSON.parse(Array(survey.cards).to_json)
      attrs[:cards] = FlowCompiler.compile!(Survey.reconcile_flows!(cards, attrs[:flows]), attrs[:flows])
    end
    attrs[:brand_palette] = BrandPalette.sanitize(payload["brand_palette"]).presence if payload.key?("brand_palette")
    # "" clears back to the platform default; anything not in BRAND_FONTS is
    # dropped the same way (the value reaches an inline style attribute).
    attrs[:brand_font] = Survey.sanitize_brand_font(payload["brand_font"]) if payload.key?("brand_font")
    attrs[:brand_font_heading] = Survey.sanitize_brand_font(payload["brand_font_heading"]) if payload.key?("brand_font_heading")
    if payload.key?("brand_answer_tint")
      attrs[:brand_answer_tint] = ActiveModel::Type::Boolean.new.cast(payload["brand_answer_tint"]) || false
    end
    if payload.key?("background_image")
      attrs[:background_image] = Survey.sanitize_background_image(payload["background_image"])
      warnings << "background_image" if payload["background_image"].present? && attrs[:background_image].nil?
    end

    survey.update!(attrs)
    # A grantee deleting a portfolio-mandated card in the editor re-appends it
    # on the next autosave — enforced at the data layer, not the editor UI.
    # Scoped to this one survey; never the org-wide backfill from a per-request hook.
    PortfolioCommonQuestionSync.ensure_cards_for_survey(survey) if payload.key?("cards")

    render json: { ok: true, id: survey.id, updated_at: survey.updated_at, warnings: warnings.uniq }
  rescue => e
    # Generic to the client, specific to Sentry (P1-16): a raw exception message
    # can carry a SQL fragment, a column name or a file path, and none of that
    # helps the person whose save just failed.
    ErrorReporting.report("SurveysController#update", e)
    render json: { ok: false, error: "Couldn't save your changes — please try again." },
           status: :unprocessable_entity
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
    elsif verdict[:ambiguous]
      render json: { ok: false, reason: could_not_verify_image_message }, status: :bad_gateway
    else
      render json: { ok: false, reason: verdict[:reason].presence || "That image isn't PG or age-appropriate for this Verto." }
    end
  rescue ActiveRecord::RecordNotFound
    raise # let it 404 rather than read as "couldn't check"
  rescue => e
    ErrorReporting.report("SurveysController#moderate_image", e)
    render json: { ok: false, reason: could_not_verify_image_message }, status: :bad_gateway
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
    ErrorReporting.report("SurveysController#pexels_search", e)
    render json: { images: [], error: "search_failed" }, status: :bad_gateway
  end

  def publish
    # P0-8. Publishing is the outward-facing act: it puts a link in front of
    # respondents who will hand over a birth date and a location. Doing that
    # under an email address nobody proved they own is the hole email
    # verification exists to close, so this is where the gate sits — rather
    # than on sign-in, which would lock people out of the product entirely if
    # SMTP were misconfigured. Building a Verto stays open.
    unless Current.user&.email_verified?
      return redirect_to survey_path(@survey), alert: t("email_confirmation.publish_blocked")
    end

    @survey.update!(
      publish_token: @survey.publish_token || SecureRandom.urlsafe_base64(18),
      published_at:  @survey.published_at  || Time.current,
      # Re-publishing after a take-down reuses the original token, so the same
      # /play link (and any printed QR code) comes back to life.
      unpublished_at: nil
    )
    redirect_to survey_path(@survey)
  end

  # POST /surveys/:id/unpublish
  # Takes a live Verto off /play. Deliberately does NOT clear publish_token:
  # that column is the public link, and a creator who unpublishes to fix a typo
  # expects the same link back afterwards. What happens next depends on whether
  # anyone answered:
  #
  #   no responses  → a fully editable draft again (nothing to misalign)
  #   has responses → closed: results kept, deck permanently frozen
  #
  # Survey#editing_locked? is what enforces the second case, so unpublishing can
  # never be used as a route to editing a deck people have already answered.
  def unpublish
    unless @survey.published?
      return redirect_to from_share_modal? ? share_survey_path(@survey) : survey_path(@survey),
                         alert: t("flash.surveys.not_live")
    end

    @survey.update!(unpublished_at: Time.current)
    notice = @survey.closed? ? t("flash.surveys.closed") :
                               t("flash.surveys.unpublished")
    # The Share modal posts this from a Turbo Frame; the redirect has to land
    # back on the panel or the frame is left with nothing to swap in (same
    # reason as update_settings' return_to).
    redirect_to from_share_modal? ? share_survey_path(@survey) : survey_path(@survey), notice: notice
  end

  # POST /surveys/:id/test_link — mint (or regenerate) the Test Mode token.
  # No email-verification gate, unlike #publish: that gate exists because
  # publishing starts collecting respondent data under an unproven identity,
  # and Test Mode records nothing — it only exposes the creator's own content
  # to people they hand the link to. Gating it would just obstruct
  # try-before-verify.
  def enable_test_link
    @survey.update!(test_token: SecureRandom.urlsafe_base64(18))
    redirect_to from_share_modal? ? share_survey_path(@survey) : survey_path(@survey, panel: "publish")
  end

  # DELETE /surveys/:id/test_link — turn the link off (404s immediately).
  def disable_test_link
    @survey.update!(test_token: nil)
    redirect_to from_share_modal? ? share_survey_path(@survey) : survey_path(@survey, panel: "publish")
  end

  # POST /surveys/:id/test_mode — the Share modal's one-step take-down into
  # Test Mode: off /play (when live) plus a test link that records nothing.
  # An existing test_token is kept, not rotated — that URL may already be in
  # testers' hands, and rotating it here would kill it as a side effect. The
  # unpublish half carries the same consequences as #unpublish (closed vs
  # back-to-draft), which the modal's confirm text spells out.
  def convert_to_test_mode
    attrs = { test_token: @survey.test_token || SecureRandom.urlsafe_base64(18) }
    attrs[:unpublished_at] = Time.current if @survey.published?
    @survey.update!(attrs)
    redirect_to share_survey_path(@survey)
  end

  # POST /surveys/:id/card_image
  # Persists an uploaded card/background image and hands back a short
  # same-origin path to store on the card, instead of the multi-MB base64
  # data-URL that used to be written straight into the cards JSON (P1-7).
  #
  # The editor calls this after moderation passes, so nothing unmoderated is
  # ever written to storage. A failure here is non-fatal on the client: it falls
  # back to the data-URL, which sanitize_image_url still accepts, so a creator
  # is never blocked from applying an image by a storage hiccup.
  def card_image
    survey = Current.organisation.surveys.kept.find(params[:id])
    if survey.editing_locked?
      return render json: { ok: false, error: editing_locked_message }, status: :locked
    end

    blob = Survey::CardImageStore.attach(survey, params[:image].to_s)
    return render json: { ok: false, error: "That image couldn't be stored." }, status: :unprocessable_entity unless blob

    render json: { ok: true, url: rails_blob_path(blob, only_path: true) }
  rescue ActiveRecord::RecordNotFound
    raise
  rescue => e
    ErrorReporting.report("SurveysController#card_image", e)
    render json: { ok: false, error: "That image couldn't be stored." }, status: :unprocessable_entity
  end

  # POST /surveys/:id/card_lottie
  # A pasted LottieFiles URL, fetched server-side, scrubbed and re-served
  # same-origin (see CardLottieStore for why hotlinking was rejected). Unlike
  # card_image there is no client-side fallback: an external URL never
  # survives the cards sanitiser, so a failure here means "not applied".
  def card_lottie
    survey = Current.organisation.surveys.kept.find(params[:id])
    if survey.editing_locked?
      return render json: { ok: false, error: editing_locked_message }, status: :locked
    end

    blob = Survey::CardLottieStore.fetch_and_attach(survey, params[:url].to_s)
    return render json: { ok: false, error: "That link doesn't look like a LottieFiles animation." }, status: :unprocessable_entity unless blob

    render json: { ok: true, url: rails_blob_path(blob, only_path: true) }
  rescue ActiveRecord::RecordNotFound
    raise
  rescue => e
    ErrorReporting.report("SurveysController#card_lottie", e)
    render json: { ok: false, error: "That animation couldn't be stored." }, status: :unprocessable_entity
  end

  # GET /surveys/:id/qr
  # The share panel's QR as a downloadable file, for posters, flyers and slide
  # decks — the panel itself renders the same SVG inline for scanning off a
  # screen. 404s for a draft: there is no public link to encode yet, and a QR
  # pointing at a dead URL is worse than no QR.
  def qr
    # ?link_id= asks for a named share link's own code, so an audience with its
    # own address gets its own printable QR rather than the Verto's. Still
    # gated on the Verto being live: a link's slug only resolves once it is.
    link = params[:link_id].present? ? @survey.survey_links.find_by(id: params[:link_id]) : nil
    key  = @survey.published? && link ? link.play_key : @survey.public_link_key
    return head :not_found if key.blank?

    send_data helpers.verto_qr_svg_document(play_survey_url(key)),
              type:        "image/svg+xml",
              disposition: "attachment",
              filename:    "#{key.parameterize}-qr.svg"
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
    # Which card carries the token intro. A cid that isn't in the deck is stored
    # as nil rather than rejected — Survey#token_intro_card_cid already falls
    # back to the welcome card, so a stale cid degrades to the old behaviour.
    if params.key?(:token_intro_cid)
      wanted = params[:token_intro_cid].to_s.strip.presence
      attrs[:token_intro_cid] =
        if wanted && Array(@survey.cards).any? { |c| c.is_a?(Hash) && c["cid"].to_s == wanted }
          wanted
        end
    end
    # Presentation switches — safe to change at any point in a Verto's life, so
    # deliberately NOT in SETTINGS_LOCKED_IN_USE. None of them re-scores an
    # answer or changes what anyone agreed to; they only affect what a
    # respondent is shown from here on. leaderboard_enabled belongs here too:
    # the standings are computed at read time from data that exists either way,
    # so the toggle only shows or hides them.
    %i[token_reveal_enabled token_back_nav_enabled token_hud_enabled share_enabled
       regions_enabled respondent_code_enabled leaderboard_enabled
       chrome_follows_verto_language].each do |flag|
      next unless params.key?(flag)
      attrs[flag] = ActiveModel::Type::Boolean.new.cast(params[flag])
    end
    if params.key?(:leaderboard_retake_policy)
      attrs[:leaderboard_retake_policy] =
        Survey.normalize_leaderboard_retake_policy(params[:leaderboard_retake_policy])
    end
    if params.key?(:respondent_code_prompt)
      attrs[:respondent_code_prompt] =
        params[:respondent_code_prompt].to_s.strip.first(200).presence
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
    # Button label for the thank-you screen's off-site link. Same cap as a
    # branch end screen's, so the two screens can't drift apart.
    if params.key?(:forward_label)
      attrs[:forward_label] = params[:forward_label].to_s.strip.first(Survey::MAX_END_LABEL).presence
    end
    if params.key?(:consent_text)
      attrs[:consent_text] = params[:consent_text].to_s.strip.first(2000).presence
    end
    # Consent-gate design image — same allowed forms as card/backdrop images
    # (stored-upload path, asset path, Pexels CDN, capped data URL) and the
    # same Pexels-only rule for the credit link. A cleared/rejected image
    # drops its credit with it, mirroring the card sanitizer.
    if params.key?(:consent_image)
      attrs[:consent_image] = Survey.sanitize_image_url(params[:consent_image])
    end
    if params.key?(:consent_image_credit)
      attrs[:consent_image_credit] = params[:consent_image_credit].to_s.strip.first(Survey::MAX_CREDIT_NAME).presence
    end
    if params.key?(:consent_image_credit_url)
      attrs[:consent_image_credit_url] = Survey.sanitize_credit_url(params[:consent_image_credit_url])
    end
    if attrs.key?(:consent_image) && attrs[:consent_image].nil?
      attrs[:consent_image_credit]     = nil
      attrs[:consent_image_credit_url] = nil
    end
    if params.key?(:end_screens)
      attrs[:end_screens] = Survey.sanitize_end_screens(JSON.parse(params[:end_screens]))
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

    # Refuse the whole request rather than applying it in part: a save that
    # silently drops half of what was asked for is harder to reason about than
    # one that plainly didn't happen. In practice each of these forms submits a
    # single field, so nothing legitimate gets caught alongside.
    if @survey.editing_locked? && (attrs.keys & SETTINGS_LOCKED_IN_USE).any?
      respond_to do |format|
        format.html { redirect_to survey_path(@survey, panel: "publish"), alert: settings_locked_message }
        format.json { render json: { ok: false, error: settings_locked_message }, status: :locked }
      end
      return
    end

    @survey.update!(attrs) if attrs.any?
    respond_to do |format|
      # The settings forms are plain full-page POSTs; the in-feed
      # consent/thank-you gate cards save the same fields via fetch + JSON.
      # Forms in the right panel's feature tabs (quiz / tokens / logic) send
      # return_tab so the reload reopens their tab instead of the Publish view.
      format.html do
        # The dashboard's Share modal posts the same fields from a Turbo Frame,
        # so it has to land back on the panel that drew them — a redirect to
        # the editor would leave the frame with no matching frame to swap in.
        if params[:return_to].to_s == "share"
          next redirect_to share_survey_path(@survey, slug_error: (slug_taken ? "taken" : nil))
        end
        return_tab = params[:return_tab].to_s.presence
        redirect_to survey_path(@survey, slug_error: (slug_taken ? "taken" : nil),
          panel: (return_tab ? nil : "publish"), tab: return_tab)
      end
      format.json { render json: { ok: true, slug_taken: slug_taken } }
    end
  end

  def shuffle_assets
    survey = Current.organisation.surveys.kept.find(params[:id])
    if survey.editing_locked?
      return redirect_to survey_path(survey), alert: editing_locked_message
    end
    AssetPopulator.new(survey, seed: SecureRandom.hex(4)).populate!
    redirect_to survey_path(survey)
  rescue => e
    ErrorReporting.report("SurveysController#shuffle_assets", e)
    redirect_to survey_path(survey), alert: t("flash.surveys.shuffle_failed")
  end

  def destroy
    survey = Current.organisation.surveys.kept.find(params[:id])
    survey.archive!
    redirect_to root_path, notice: t("flash.surveys.archived", name: survey.theme.presence || survey.title.presence || "Verto")
  end

  # POST /surveys/:id/restore
  # Undo an archive. Nothing about archiving destroys anything — deleted_at is a
  # soft flag and the scopes have always been there — so this is just clearing
  # it. It stays a DRAFT: publish_token and published_at were never touched by
  # archiving, but re-opening a Verto to responders is a separate decision the
  # creator should make deliberately, so unpublished_at is stamped rather than
  # having the old link quietly go live again with the restore.
  def restore
    survey = Current.organisation.surveys.archived.find(params[:id])
    attrs  = { deleted_at: nil }
    # A Verto that had a live link comes back NOT live. Archiving never cleared
    # publish_token, so without this the old /play link would quietly start
    # working again the moment it's restored — re-opening to responders should be
    # its own deliberate click.
    attrs[:unpublished_at] = Time.current if survey.publish_token.present? && survey.unpublished_at.nil?
    survey.update!(attrs)

    redirect_to root_path,
      notice: t("flash.surveys.restored", name: survey.title.presence || survey.theme.presence || "Verto")
  end

  def destroy_forever
    survey = Current.organisation.surveys.archived.find(params[:id])
    name   = survey.theme.presence || survey.title.presence || "Verto"
    Survey.transaction { survey.destroy! }
    redirect_to root_path, notice: t("flash.surveys.destroyed_forever", name: name)
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
    redirect_to root_path, notice: t("flash.surveys.bulk_archived", count: count)
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
    redirect_to root_path, notice: t("flash.surveys.bulk_destroyed_forever", count: count)
  end

  # How many standings rows the creator's results page lists. More generous
  # than the player's top ten — this is the person running the game — but
  # still bounded: an imported Verto can hold thousands of responses, and a
  # page is not an export.
  RESULTS_LEADERBOARD_ROWS = 20

  def results
    @date_range = params[:range].presence
    base, @segments, @active_segment = resolve_result_segments(@survey, params[:segment], @date_range)
    @overall_total  = base.count

    @responses  = @active_segment[:scope]
    @total      = @active_segment[:count]
    @aggregated = aggregate_results(Array(@survey.cards), @responses)

    # The creator's view of the board. Whole-Verto on purpose — identities
    # span the date/segment filters, and the retake policy already decides
    # which runs count, so a filtered board would show partial sums matching
    # nothing any respondent was shown. Same read-time alias backfill as the
    # player endpoint, bounded to the rendered rows.
    if @survey.leaderboard_active?
      standings = TokenLeaderboard.standings(@survey)
      @leaderboard_player_count = standings.size
      @leaderboard = standings.first(RESULTS_LEADERBOARD_ROWS)
      digests = @leaderboard.map { |e| e[:key_digest] }
      digests.each { |d| PlayerAlias.ensure_for!(survey: @survey, key_digest: d) }
      @leaderboard_names = @survey.player_aliases.where(key_digest: digests)
                                  .pluck(:key_digest, :anon_name).to_h
    end
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
        # `responses` rides on the card, not on each segment's aggregate: the
        # scale is a property of the question, and repeating it per segment
        # would multiply it by however many segments are being compared.
        { index: idx, type: card["type"], text: card["text"], options: card["options"],
          demographic: card["demographic"].present?,
          responses: (TapScales.for_card(card).map { |r| r.slice("key", "label") } if card["type"].to_s == "tap_card") }.compact
      },
      segments: segments.map { |seg| seg.slice(:id, :label, :count) },
      aggregates: segments.each_with_object({}) { |seg, acc| acc[seg[:id]] = aggregate_results(cards, seg[:scope]) }
    }
  end

  # POST /surveys/:id/generate_card
  # Generates a single new question card using Claude, renders its HTML partial.
  def generate_card
    survey = Current.organisation.surveys.kept.find(params[:id])
    if survey.editing_locked?
      return render json: { ok: false, error: editing_locked_message }, status: :locked
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
    # The card JSON as well as its markup. translate_card! above has just paid
    # Claude for one translation per secondary locale, and returning only HTML
    # threw every one of them away: the editor seeds its translation store at
    # connect() and has no other way to learn about a card added after that, so
    # the next autosave wrote the card back monolingual.
    render json: { ok: true, card: card, html: html }
  rescue => e
    ErrorReporting.report("SurveysController#generate_card", e)
    render json: { ok: false, error: friendly_generate_error(e) }, status: :unprocessable_entity
  end

  # POST /surveys/:id/generate_flow
  # Generates a NAMED FLOW (3-6 cards for one audience segment) from a creator
  # prompt, rendering each card's editor partial. Nothing is persisted here —
  # the client splices the cards in, creates the flow in its working set and
  # wires the answer; autosave persists the lot (same contract as generate_card).
  def generate_flow
    survey = Current.organisation.surveys.kept.find(params[:id])
    if survey.editing_locked?
      return render json: { ok: false, error: editing_locked_message }, status: :locked
    end
    body   = JSON.parse(request.body.read)
    prompt = body["prompt"].to_s.strip.first(500)
    if prompt.blank?
      return render json: { ok: false, error: "Describe what this flow should ask." }, status: :unprocessable_entity
    end

    # Off the request thread: FlowGenerator plus one translation call per
    # secondary locale is up to six sequential Claude calls, and three of those
    # in flight occupied every Puma thread this instance has. The editor polls
    # FlowGenerationsController#show and splices when the cards land.
    generation = survey.flow_generations.create!(
      user: Current.user,
      payload: {
        "prompt"     => prompt,
        "answer"     => body["answer"].to_s.strip.first(100).presence,
        "entry_text" => body["entry_text"].to_s.strip.first(200).presence
      }
    )
    GenerateFlowJob.perform_later(generation.id)

    render json: { ok: true, id: generation.id, poll_url: flow_generation_path(generation) },
           status: :accepted
  rescue => e
    ErrorReporting.report("SurveysController#generate_flow", e)
    render json: { ok: false, error: friendly_generate_error(e) }, status: :unprocessable_entity
  end

  # POST /surveys/:id/restore_card
  # Bring a recently deleted card back, rendered ready to splice — the same
  # contract as render_card, so the editor reuses its insertion path.
  #
  # The card keeps its original cid, so any route that pointed at it resolves
  # again. Nothing is removed from the bin here: the card is only truly back once
  # the editor's autosave stores a deck containing it, and record_deleted_cards
  # takes it out of the bin at that point.
  def restore_card
    survey = Current.organisation.surveys.kept.find(params[:id])
    if survey.editing_locked?
      return render json: { ok: false, error: editing_locked_message }, status: :locked
    end

    body = JSON.parse(request.body.read)
    card = survey.deleted_card(body["cid"])
    unless card
      return render json: { ok: false, error: "That card is no longer available to restore." },
                    status: :not_found
    end

    # The card JSON travels with the markup so the editor can seed its
    # translation store — without it, restoring a translated card stripped its
    # i18n on the next autosave, the BUG-030 shape on one more path.
    render json: { ok: true, cid: card["cid"], card: card, html: render_card_html(survey, card) }
  rescue => e
    ErrorReporting.report("SurveysController#restore_card", e)
    render json: { ok: false, error: "That card couldn't be restored." }, status: :unprocessable_entity
  end

  # POST /surveys/:id/optimise_card
  # AI-rewrite ONE flagged card so it satisfies the Rules of the Game, fixing the
  # editor-listed issues while keeping the answer type and intent. Returns the
  # optimised card JSON + its rendered editor partial, so the editor can swap it
  # in place and the traffic light turns green.
  def optimise_card
    @survey = survey = Current.organisation.surveys.kept.find(params[:id])
    if survey.editing_locked?
      return render json: { ok: false, error: editing_locked_message }, status: :locked
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
      # Fall back to the card's own description like text/options/outcome do.
      # This was the one field with no fallback: when the optimiser omitted it,
      # `.compact` dropped the key and the creator's description was destroyed —
      # the exact field-loss shape BUG-018 was supposed to have closed.
      "description" => optimised["description"].to_s.presence || card["description"],
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
    ErrorReporting.report("SurveysController#optimise_card", e)
    render json: { ok: false, error: friendly_generate_error(e) }, status: :unprocessable_entity
  end

  # POST /surveys/:id/render_card
  # Renders the HTML partial for a given card JSON (used by "Start from Blank" flow).
  def render_card
    survey = Current.organisation.surveys.kept.find(params[:id])
    if survey.editing_locked?
      return render json: { ok: false, error: editing_locked_message }, status: :locked
    end
    card   = JSON.parse(request.body.read)
    # Stamp a stable cid now so the freshly inserted card is a valid
    # answer-branching target (and carries its identity) before the first save.
    card["cid"] = card["cid"].to_s.strip.presence || "c_#{SecureRandom.hex(3)}" if card.is_a?(Hash)

    html = render_card_html(survey, card)
    render json: { ok: true, html: html }
  rescue => e
    ErrorReporting.report("SurveysController#render_card", e)
    render json: { ok: false, error: "Couldn't build that card — please try again." },
           status: :unprocessable_entity
  end

  # POST /surveys/:id/demographic_card
  # Inserts one of the OPT-IN demographic questions (Heritage/Neurodiversity —
  # DemographicQuestions::OPTIONAL_CARDS) from the add-question modal's
  # Demographics tiles. The card arrives fully formed from the registry in the
  # Verto's default locale; response follows generate_card's {ok, card, html}
  # shape so the client's seedCardStore receives the i18n prefill.
  def add_demographic_card
    survey = Current.organisation.surveys.kept.find(params[:id])
    if survey.editing_locked?
      return render json: { ok: false, error: editing_locked_message }, status: :locked
    end

    key  = params[:key].to_s
    card = DemographicQuestions.optional_card(key, locale: survey.default_locale)
    unless card
      return render json: { ok: false, error: "Unknown demographic question." }, status: :unprocessable_entity
    end
    # Heritage is the one registry card that isn't the same everywhere: with an
    # audience country set, the global nine categories give way to the five
    # people in that country actually identify with. HeritageOptions returns nil
    # when Claude couldn't be reached or answered unusably, and country_heritage_card
    # hands back the plain registry card for a nil — the creator gets a working
    # Heritage question either way, just an untailored one.
    tailored = false
    if key == "heritage" && survey.audience_country.present?
      five = HeritageOptions.for(country: survey.audience_country, locale: survey.default_locale)
      card = DemographicQuestions.country_heritage_card(
        country: survey.audience_country, five: five, locale: survey.default_locale
      )
      tailored = card["heritage_country"].present?
    end
    # Belt-and-braces behind the tile grey-out (which reads the live DOM):
    # one of each per deck, or the answer sync's first-match would be arbitrary.
    if Array(survey.cards).any? { |c| c.is_a?(Hash) && c["demographic_key"] == key }
      return render json: { ok: false, error: "This Verto already asks that." }, status: :unprocessable_entity
    end

    card["cid"] = "c_#{SecureRandom.hex(3)}"
    if tailored
      # A tailored card's options were written moments ago, so there is nothing
      # in the locale files to prefill from — it takes the same route a freshly
      # generated card takes (one SurveyTranslator call per secondary locale,
      # TranslationCache-backed) rather than a second, parallel path.
      card = translate_card!(card, survey)
    else
      # The translations are already sitting in the locale files — prefill i18n
      # so a multilingual Verto's next autosave doesn't persist the card
      # monolingual. No Claude call needed, unlike generate_card.
      (Array(survey.locales) - [ survey.default_locale ]).each do |loc|
        tr = DemographicQuestions.optional_card(key, locale: loc)
        (card["i18n"] ||= {})[loc] =
          { "text" => tr["text"], "description" => tr["description"], "options" => tr["options"] }.compact
      end
    end

    render json: { ok: true, card: card, html: render_card_html(survey, card) }
  rescue ActiveRecord::RecordNotFound
    raise # cross-org (or deleted) Verto — a real 404, not a swallowed 422
  rescue => e
    ErrorReporting.report("SurveysController#add_demographic_card", e)
    render json: { ok: false, error: "Couldn't add that question — please try again." },
           status: :unprocessable_entity
  end

  # POST /surveys/:id/audience_country
  # The Verto's audience country — which today means one thing: whether the
  # Heritage question asks in global categories or the ones this country's
  # people use.
  #
  # Deliberately NOT part of update_settings. The heritage card is materialised
  # into surveys.cards when it's inserted, so a country change has to rewrite an
  # existing card's options or the setting is a lie — and that means a Claude
  # call. Hanging one off update_settings would put an AI throttle on the ~40
  # ordinary settings that share it, and every toggle in the editor would start
  # counting against an AI budget.
  def update_audience_country
    # editing_locked? is `published? || responses.exists?`, so passing it means
    # nobody has answered yet. That is exactly when rewriting an options list is
    # safe: there are no stored demographic_heritage values to orphan. Once a
    # Verto is live its audience is settled along with the rest of its content.
    if @survey.editing_locked?
      return redirect_to survey_path(@survey, panel: "publish"), alert: settings_locked_message
    end

    country = Survey.normalize_audience_country(params[:audience_country])
    @survey.update!(audience_country: country)
    retailor_heritage_card!(@survey)

    redirect_to survey_path(@survey, panel: "publish")
  rescue => e
    ErrorReporting.report("SurveysController#update_audience_country", e, survey_id: @survey&.id)
    redirect_to survey_path(@survey, panel: "publish"),
                alert: t("flash.surveys.audience_country_failed")
  end

  private

  # Rebuild the deck's Heritage card for the Verto's current audience country,
  # if it has one of each. A no-op for a deck without the card, which is the
  # common case — most Vertos never add it, and changing the country then costs
  # nothing.
  #
  # Rewrites in place rather than appending: the card's position is the key
  # every answer is stored under, so it has to keep it.
  def retailor_heritage_card!(survey)
    cards = Array(survey.cards).map { |c| c.is_a?(Hash) ? c.dup : c }
    idx   = cards.find_index { |c| c.is_a?(Hash) && c["demographic"] && c["demographic_key"] == "heritage" }
    return if idx.nil?

    rebuilt =
      if survey.audience_country.present?
        five = HeritageOptions.for(country: survey.audience_country, locale: survey.default_locale)
        DemographicQuestions.country_heritage_card(
          country: survey.audience_country, five: five, locale: survey.default_locale
        )
      else
        # Cleared back to "not set" — the card goes back to the global taxonomy,
        # rather than keeping a country's list the Verto no longer claims.
        DemographicQuestions.optional_card("heritage", locale: survey.default_locale)
      end
    return if rebuilt.nil?

    # Keep the card's identity and anything the creator did to it that isn't the
    # taxonomy — its cid (logic and flows point at it) and its imagery. Only the
    # options, the Other box and the provenance change.
    card = cards[idx]
    card["options"] = rebuilt["options"]
    # Both ride with the taxonomy: the Other box exists because five categories
    # miss people, and the provenance has to stop claiming a country the card
    # is no longer built for.
    rebuilt["allow_other"] ? card["allow_other"] = true : card.delete("allow_other")
    if rebuilt["heritage_country"].present?
      card["heritage_country"] = rebuilt["heritage_country"]
    else
      card.delete("heritage_country")
    end
    # The old list's translations describe options that no longer exist, and
    # localized_card merges by position — leaving them would show a French
    # respondent the previous country's categories.
    card.delete("i18n")

    # Only the rebuilt card is translated, not the deck: translate_cards! would
    # overwrite every card's i18n entry from the translation cache, silently
    # undoing any translation the creator had hand-corrected.
    cards[idx] = translate_card!(card, survey)
    survey.update!(cards: cards)
  end

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

  # True when a publish-lifecycle action was posted from the dashboard's Share
  # modal (its forms send return_to=share), so the redirect must re-render the
  # modal's Turbo Frame rather than the editor.
  def from_share_modal? = params[:return_to].to_s == "share"

  def set_survey
    @survey = Current.organisation.surveys.kept.without_report_text.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    # A signed-in user on the editor URL of a Verto that isn't in their
    # account — same wrong-link-shared story as the unauthenticated case
    # below, same branded explainer. Other actions keep the plain 404.
    raise unless action_name == "show" && request.format.html?
    render_private_link_page
  end

  # Authentication#request_authentication redirects to sign-in — right for the
  # app proper, but the editor URL (/surveys/:id) is what a creator gets by
  # copying the address bar instead of the /play share link, and the person
  # opening it is usually a would-be respondent. Show them a branded page that
  # says to publish the Verto and share the /play link instead. return_to is
  # still stored, so the creator's own Sign-in path lands back in the editor.
  def request_authentication
    return super unless action_name == "show" && request.get? && request.format.html?
    session[:return_to_after_authenticating] = request.url
    render_private_link_page
  end

  # This can run from request_authentication, i.e. before the switch_locale
  # around_action has wrapped the request — resolve the locale explicitly so
  # the page still comes up in the visitor's language.
  def render_private_link_page
    I18n.with_locale(resolve_locale) do
      render "surveys/private_link", layout: "fullscreen", status: :not_found
    end
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
  # Stage an import for the background job: the wizard's answers (resolved here,
  # where params and the org are in scope) plus whatever that door needs to do
  # the read. `result` is filled in by the job.
  def enqueue_import(kind, extra = {})
    build = Current.organisation.verto_builds.create!(
      user: Current.user, kind: kind,
      payload: wizard_import_payload(nil).merge(extra)
    )
    yield build if block_given?
    BuildVertoJob.perform_later(build.id)
    build
  end

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
    cards  = DemographicQuestions.append_to(cards, locale: payload["default_locale"])

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
    # Translation and imagery are the slow tail of an import — five Claude calls
    # on a five-language deck, plus a run of Pexels lookups — and they used to run
    # right here, on a request thread. The creator goes straight to the editor now
    # and the cards fill in behind them. The digest is what stops the job writing
    # a stale deck over an edit they make in the meantime; see the job.
    FinishVertoSetupJob.perform_later(survey.id, VertoGeneration.cards_digest(survey))
    survey
  end

  # Pre-populate a freshly created Verto's imagery. Best-effort: a populator
  # failure (e.g. a transient Pexels issue) must never block Verto creation.
  def auto_populate_assets!(survey)
    VertoGeneration.auto_populate_assets!(survey)
  end

  # Snapshot the SELECTED Common Questions into Verto-card hashes. Takes
  # individual question ids (the wizard lets creators pick questions, not just
  # whole sets) and only honours ids belonging to a set this org may use —
  # so a partner can't splice in questions from a set not shared with them.
  # Each card carries common_question_id + set_id so cross-Verto results
  # aggregation can cluster answers by question identity.
  def resolve_common_cards(ids_param)
    ids = Array(ids_param).map(&:to_i).reject(&:zero?)
    accessible_ids = accessible_common_question_sets.map(&:id)
    picked = ids.any? ?
      CommonQuestion.where(id: ids, common_question_set_id: accessible_ids)
                    .order(:common_question_set_id, :position).to_a : []

    # Portfolio-mandated questions (agreed with a funder at onboarding) are
    # forced onto every new Verto regardless of what the creator picks —
    # unlike the rest of this method's picks, these aren't opt-in.
    mandatory = PortfolioCommonQuestionSync.mandatory_common_questions_for(Current.organisation).to_a
    (mandatory + picked).uniq(&:id).map(&:to_card)
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
    VertoGeneration.friendly_error(e)
  end

  # Translate the survey's primary cards into each secondary language and store
  # the result in each card's i18n map. Per-language failures are non-fatal —
  # that language simply falls back to the primary text until re-translated.
  def translate_survey!(survey)
    VertoGeneration.translate_survey!(survey)
  end

  # Translate freshly-generated cards into the Verto's secondary languages,
  # returning them with their i18n maps populated.
  #
  # ONE translator call per locale carrying the whole batch — never one per card.
  # SurveyTranslator is built for that: it runs TranslationCache.lookup_many over
  # the array and sends only the misses, in a single Claude call. Translating
  # card-by-card defeated both, so a 6-card flow on a 5-language Verto fired 30
  # sequential calls, each bounded at ANTHROPIC_TIMEOUT_SECONDS, on one of only
  # three Puma threads — an editor action that could 502 the instance by itself.
  #
  # Mirrors VertoGeneration.translate_survey!, including the rescue position:
  # it sits INSIDE the loop so one failing locale doesn't discard the merges
  # already accumulated for the others.
  #
  # Order is load-bearing — merge_card_translations pairs source to translation
  # by index — so never filter or reorder between the call and the merge.
  # Lives on VertoGeneration so GenerateFlowJob runs the identical pass.
  def translate_cards!(cards, survey)
    VertoGeneration.translate_cards!(cards, survey)
  end

  # Single-card convenience — generate_card and optimise_card each produce one
  # card, so their per-locale calls are the floor rather than a fan-out.
  def translate_card!(card, survey)
    translate_cards!([ card ], survey).first
  end

  # Renders a card's editor partial. With no `idx` the card is treated as a new
  # one appended to the deck (the add-question flow); with an explicit `idx` it's
  # rendered in place at that position (the optimise flow), so its card number
  # and progress match where it already sits.
  def set_survey_including_archived
    @survey = Current.organisation.surveys.find(params[:id])
  end
end
