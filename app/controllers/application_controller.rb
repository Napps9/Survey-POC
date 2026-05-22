class ApplicationController < ActionController::Base
  include Authentication
  include OrganisationScope
  allow_browser versions: :modern

  around_action :switch_locale

  private

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
