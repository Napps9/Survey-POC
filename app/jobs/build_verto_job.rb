# Builds a Verto from a wizard submission: generation, then translation, then
# imagery. Between 30 and 120 seconds of Claude and Pexels calls that used to
# run inline on a Puma request thread (P0-3).
#
# Everything needing the request context — authorization, param validation, and
# resolving which Common Questions the org may actually use — has already
# happened in SurveysController#generate and is baked into the build's payload.
# This job does no permission checks of its own precisely because it can't: it
# has no Current.organisation, and inventing one here would be the wrong place
# for that decision to live.
class BuildVertoJob < ApplicationJob
  queue_as :default

  # No retries. Every failure mode here is either deterministic (a malformed
  # payload) or already retried inside the Anthropic client, and a silent retry
  # of a 120s generation would bill the account twice for one creation while the
  # creator watches a spinner. A failed build shows the reason and offers a
  # retry the creator chooses.
  discard_on StandardError do |job, error|
    build = VertoBuild.find_by(id: job.arguments.first)
    ErrorReporting.report("BuildVertoJob", error, verto_build_id: build&.id)
    build&.fail!(VertoGeneration.friendly_error(error))
  end

  def perform(verto_build_id)
    build = VertoBuild.find_by(id: verto_build_id)
    return unless build
    # Already handled — a duplicate delivery must not bill a second generation.
    return if build.finished? || build.running?

    build.start!

    if build.import?
      run_import(build)
      # An import stops here on purpose. What happens next — straight to the
      # editor, or pause at the review screen because some questions break the
      # design rules — is the creator's call, and resolving it needs the request
      # context the job doesn't have.
      return build.succeed!(nil)
    end

    survey = create_survey(build)

    # Both are best-effort inside: a Verto with untranslated cards or no imagery
    # is still a usable Verto, and failing the build here would throw away a
    # generation the creator already paid for.
    VertoGeneration.translate_survey!(survey)
    VertoGeneration.auto_populate_assets!(survey)

    build.succeed!(survey)
  end

  private

  # Run the importer for this build's door and stash its output on the build for
  # the resume step. Raising here is fine — discard_on records the reason.
  def run_import(build)
    p      = build.payload
    locale = p["default_locale"]

    result =
      case build.kind
      when "import_manual"
        ManualQuestionImporter.new.call(text: p["text"].to_s, locale: locale)
      when "import_google_form"
        # The token is fetched here from the build's user rather than carried in
        # the payload — an access token has no business sitting at rest in a
        # JSON column, and the client refreshes it if it expired while queued.
        token = GoogleOauthService.client_for(build.user).access_token
        GoogleFormsImporter.call(GoogleFormsClient.new(token).fetch(p["form_id"]))
      when "import_pdf"
        # Re-read the staged upload rather than carrying its bytes through the
        # queue; the attachment is purged with the build.
        PdfQuestionImporter.new.call(pdf_data: Base64.strict_encode64(build.source_file.download), locale: locale)
      else
        raise ArgumentError, "unknown import kind #{build.kind.inspect}"
      end

    raise ImportedNothing if Array(result["cards"]).empty?

    build.update!(payload: p.merge("result" => result))
  end

  # No questions found — a real, creator-fixable outcome rather than a crash,
  # so it carries wording they can act on.
  class ImportedNothing < StandardError
    def message = "we couldn't find any questions to import — try a different file or wording."
  end

  def create_survey(build)
    p = build.payload
    common_cards = Array(p["common_cards"])

    result =
      if p["key_insight"].to_s.strip.empty?
        # Common-Questions-only deck: nothing to generate, so no Claude call.
        { "title" => p["theme"], "description" => nil, "theme" => p["theme"],
          "audience_age" => p["audience_age"], "key_insight" => nil,
          "cards" => [ { "type" => "welcome_card", "title" => p["theme"], "text" => p["theme"] } ] + common_cards }
      else
        SurveyGenerator.new.call(
          theme:        p["theme"],
          audience_age: p["audience_age"],
          key_insight:  p["key_insight"],
          notes:        p["notes"].to_s,
          locale:       p["default_locale"],
          common_cards: common_cards,
          quiz:         !!p["quiz"]
        )
      end

    survey = build.organisation.surveys.create!(
      title:        result["title"],
      description:  result["description"],
      theme:        result["theme"].presence || p["theme"],
      audience_age: result["audience_age"].presence || p["audience_age"],
      key_insight:  result["key_insight"].presence || p["key_insight"],
      cards:        DemographicQuestions.append_to(result["cards"]),
      show_results_comparison: !!p["show_results_comparison"],
      quiz:           !!p["quiz"],
      brand_palette:  p["brand_palette"].presence,
      default_locale: p["default_locale"],
      locales:        Array(p["locales"])
    )

    # Remember the palette as the account default so the next Verto inherits it.
    build.organisation.update(default_brand_palette: p["brand_palette"]) if p["brand_palette"].present?

    survey
  end
end
