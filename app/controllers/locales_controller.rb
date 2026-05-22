# Switches the platform UI language. Works on public pages too (the player and
# unauthenticated screens), so it skips auth and organisation scoping.
class LocalesController < ApplicationController
  allow_unauthenticated_access
  skip_before_action :set_current_organisation

  def update
    locale = SupportedLocales.coerce(params[:locale])
    cookies.permanent[:locale] = { value: locale, same_site: :lax }
    Current.user&.update(preferred_locale: locale)
    redirect_back fallback_location: root_path
  end
end
