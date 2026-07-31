# Email verification (P0-8). Signup previously accepted any address with no
# proof it belonged to the person, so a Verto could be published — and start
# collecting respondents' birth dates and locations — under an address its
# owner never consented to.
#
# The gate is on PUBLISHING rather than on sign-in, deliberately. SMTP is
# optional in this deployment (config/initializers/mailer.rb only warns when
# SMTP_ADDRESS is unset), so a hard sign-in gate would lock every new customer
# out of the product the moment mail was misconfigured. Gating the outward-
# facing action instead closes the actual hole — nobody collects responses
# under an unowned address — while leaving a person able to build and to ask
# for another email.
class EmailConfirmationsController < ApplicationController
  allow_unauthenticated_access only: :show
  skip_before_action :set_current_organisation, only: :show
  rate_limit to: 5, within: 10.minutes, only: :create,
             with: -> { redirect_back fallback_location: root_path, allow_other_host: false,
                                      alert: t("email_confirmation.too_many") }

  # The link in the email. Unauthenticated on purpose: people open these on a
  # phone that isn't signed in, and a link that demanded a login first would
  # send them round a loop. The signed token is the proof, not the session.
  def show
    user = User.find_by_token_for(:email_confirmation, params[:token])

    if user.nil?
      return redirect_to root_path, alert: t("email_confirmation.invalid")
    end

    # Captured before verify_email!, which is idempotent — someone re-opening
    # the link from their inbox a week later must not get a second welcome.
    first_confirmation = !user.email_verified?
    user.verify_email!
    deliver_welcome(user) if first_confirmation

    redirect_to root_path, notice: t("email_confirmation.confirmed")
  end

  # Resend, from the banner. Rate-limited because it sends mail to an address
  # the requester has already named — without a cap this is a mail-bomb button.
  def create
    if Current.user.email_verified?
      return redirect_back fallback_location: root_path,
                           notice: t("email_confirmation.already_confirmed")
    end

    deliver_confirmation(Current.user)
    redirect_back fallback_location: root_path, allow_other_host: false,
                  notice: t("email_confirmation.resent", email: Current.user.email_address)
  end

  # Shared with RegistrationsController. A delivery failure must never take the
  # signup down with it — the account exists, and the banner offers a resend.
  def self.deliver(user)
    EmailConfirmationsMailer.confirm(user).deliver_later
  rescue => e
    ErrorReporting.report("EmailConfirmationsMailer", e, user_id: user.id)
    nil
  end

  private

  def deliver_confirmation(user)
    self.class.deliver(user)
  end

  # Same discipline as .deliver: the confirmation itself has already succeeded
  # and been persisted by this point, so a mail failure here must not turn a
  # working confirmation link into an error page.
  def deliver_welcome(user)
    WelcomeMailer.welcome(user).deliver_later
  rescue => e
    ErrorReporting.report("WelcomeMailer", e, user_id: user.id)
    nil
  end
end
