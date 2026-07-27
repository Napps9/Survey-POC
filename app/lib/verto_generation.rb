# The build steps that turn a wizard submission into a finished Verto, in one
# place so the controller and BuildVertoJob run identical work.
#
# These used to be private methods on SurveysController, executed inline on a
# Puma request thread. They are the slow part of creation — a translation pass
# is one Claude call per secondary language, and asset population talks to
# Pexels — which is exactly why they moved to a job (P0-3).
module VertoGeneration
  module_function

  # Fill in every secondary language's i18n entries. Each locale is independent:
  # one failing translation leaves that language on the source text rather than
  # losing the whole deck, which is why the rescue is inside the loop.
  def translate_survey!(survey)
    return unless survey.secondary_locales.any?

    cards  = Array(survey.cards)
    source = survey.default_locale
    survey.secondary_locales.each do |loc|
      translated = SurveyTranslator.new.call(cards: cards, target_locale: loc, source_locale: source)
      cards = Survey.merge_card_translations(cards, loc, translated)
    rescue => e
      ErrorReporting.report("SurveyTranslator", e, locale: loc)
    end
    survey.update!(cards: cards)
  end

  # Every new Verto opens with imagery rather than a blank editor. Best-effort:
  # a Pexels outage must not fail the creation, it just means an unillustrated
  # deck the creator can fill in themselves.
  def auto_populate_assets!(survey)
    AssetPopulator.new(survey).populate!
  rescue => e
    ErrorReporting.report("AssetPopulator", e)
  end

  # Creator-facing failure text: the API's own message when Claude returned one
  # (rate limit, overloaded, bad key — all things the creator can act on), and
  # otherwise a bounded version of the exception.
  def friendly_error(e)
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

    # Both key shapes: the SDK hands back symbol keys, a re-parsed body strings.
    body.dig(:error, :message) || body.dig("error", "message")
  end
end
