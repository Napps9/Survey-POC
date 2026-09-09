# A respondent's own account: the Vertos they kept.
#
# Outside /play/ deliberately. That path is the service worker's entire scope
# and its HTML is cached for offline use; a signed-in page has no business in a
# shared device's cache. It is also never embedded, which is why its cookie can
# be SameSite=Lax.
class YouController < ApplicationController
  include PlayerAuthentication

  allow_unauthenticated_access
  skip_before_action :set_current_organisation
  layout "fullscreen"

  # Signed out is a real state here, not a redirect: there is no sign-in form
  # to send anyone to. The page explains what /you is and how to get one.
  allow_signed_out_players only: :show

  before_action :no_store

  def show
    @claims = if player_signed_in?
      current_player.player_claims
                    .includes(:survey, :response)
                    .newest_first
                    .reject { |c| c.survey.nil? || c.survey.deleted_at.present? }
    else
      []
    end
  end

  def sign_out
    terminate_player_session
    redirect_to you_path, notice: t("you.signed_out")
  end

  # Self-service erasure. The account, its sessions, its outstanding links and
  # its claims — never the pseudonymous Response rows, which are the creator's
  # research data and are not this person's to delete from here. See
  # docs/DATA_RETENTION.md.
  def destroy
    player = current_player
    terminate_player_session
    player.destroy
    redirect_to you_path, notice: t("you.deleted")
  end

  private

  # A page listing what one person has answered must not be written to a
  # shared browser's disk cache. Same header Comms::TrackingController sets.
  def no_store
    response.headers["Cache-Control"] = "no-store"
  end
end
