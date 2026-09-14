# Switches the platform UI language. Works on public pages too (the player and
# unauthenticated screens), so it skips auth and organisation scoping.
#
# A signed-in respondent's choice is saved on their account as well as in the
# cookie, the way a creator's is: the cookie is this browser's memory and the
# account is theirs, and the emails PlayerAudience sends read the account.
class LocalesController < ApplicationController
  include PlayerAuthentication

  allow_unauthenticated_access
  allow_signed_out_players
  skip_before_action :set_current_organisation

  def update
    locale = SupportedLocales.coerce(params[:locale])
    cookies.permanent[:locale] = { value: locale, same_site: :lax }
    Current.user&.update(preferred_locale: locale)
    Current.player&.update(preferred_locale: locale)
    redirect_back fallback_location: root_path
  end
end
