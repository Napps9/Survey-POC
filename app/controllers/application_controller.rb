class ApplicationController < ActionController::Base
  include Authentication
  include OrganisationScope
  allow_browser versions: :modern

  around_action :switch_locale
  before_action :discourage_indexing

  # Paths whose URL *is* the authorisation — the token is the key, so an indexed
  # URL publishes the capability rather than just a page. public/robots.txt asks
  # crawlers not to fetch these; this is the half that binds a crawler which
  # ignores it, and the half that still applies when a link leaks into a tweet,
  # a Slack unfurl or a public doc rather than being crawled from the site.
  #
  # Matched on path rather than controller so the mounted Blazer engine — whose
  # controllers inherit from this class but are not ours to annotate — is
  # covered by the same rule.
  NOINDEX_PATHS = %r{\A/(play|test|invites|funder_invites|blazer|e)(/|\z)}

  # What a respondent is offered once they finish — results comparison, the
  # Share button, the regions map. The named send link they arrived through
  # answers first (its overrides are the reason it exists), otherwise the Verto
  # does. Both objects answer #compare_results?, #share_button? and
  # #regions_map?, so nothing downstream branches on which one it got.
  #
  # Lives here rather than on PlayerController because player/show.html.erb is
  # also rendered by SurveysController#preview, where there is no link at all.
  helper_method def play_settings
    @survey_link || @survey
  end

  private

  def discourage_indexing
    return unless NOINDEX_PATHS.match?(request.path)

    response.set_header("X-Robots-Tag", "noindex, nofollow")
  end

  # Resolves the acting user for the mounted Blazer engine, whose controllers
  # inherit from this class (and skip its auth filters). Named by `user_method`
  # in config/blazer.yml so Blazer can attribute audits/queries; nothing in the
  # app itself calls it. Access is gated separately in config/routes.rb.
  def current_blazer_staff
    BlazerAccess.user_for(request)
  end

  # Wrap the request in the resolved UI locale. Runs after authentication /
  # organisation filters, so Current.user is available when present.
  def switch_locale(&action)
    Current.locale = resolve_locale
    I18n.with_locale(Current.locale, &action)
  end

  # Priority: explicit ?locale= → saved cookie → signed-in user's preference →
  # browser Accept-Language → app default. Only ever returns a supported code.
  def resolve_locale
    candidate = [
      params[:locale],
      cookies[:locale],
      Current.user&.preferred_locale,
      locale_from_header
    ].compact.find { |c| SupportedLocales.supported?(c) }

    candidate || I18n.default_locale.to_s
  end

  def locale_from_header
    header = request.env["HTTP_ACCEPT_LANGUAGE"]
    return nil if header.blank?

    header.split(",")
          .map { |tag| tag.split(";").first.to_s.strip.split("-").first.downcase }
          .find { |code| SupportedLocales.supported?(code) }
  end
end
