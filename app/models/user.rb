class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :identities, dependent: :destroy

  validates :name,          presence: true
  validates :email_address, presence: true, uniqueness: { case_sensitive: false },
                            format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password,      length: { minimum: 12 }, allow_nil: true
  has_many :memberships, dependent: :destroy
  has_many :organisations, through: :memberships

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  # Google OAuth tokens for the "Connect to Google Sheets" results export.
  # Encrypted at rest — they grant write access to the user's Drive files.
  encrypts :google_refresh_token
  encrypts :google_access_token

  # A token that cannot be decrypted is not a token. Rails raises
  # ActiveRecord::Encryption::Errors::Decryption when the key that encrypted a
  # value is no longer the key in use — which is what a recreated Render service
  # produces, since ACTIVE_RECORD_ENCRYPTION_* are generateValue and are minted
  # fresh with the service.
  #
  # This method is called from surveys/index.html.erb, the DASHBOARD, so letting
  # that error out meant a key change took the app's home page down for every
  # affected user — including the page they would have used to reconnect. Now it
  # degrades to "not connected", which is both true (the stored token is
  # unusable) and recoverable (they can reconnect, which overwrites it).
  #
  # Deliberately narrow: only the decryption error is swallowed, and only here
  # and in google_credentials. Anything else still raises.
  def google_connected?
    google_refresh_token.present?
  rescue ActiveRecord::Encryption::Errors::Decryption
    report_undecryptable_google_token
    false
  end

  # The refresh token, or nil if it can no longer be decrypted. Callers already
  # handle a missing token (GoogleOauthService raises NotConnected and the UI
  # offers a reconnect), so nil routes an unreadable token into a path that
  # already exists rather than a 500 nobody planned for.
  def google_refresh_token_if_readable
    google_refresh_token
  rescue ActiveRecord::Encryption::Errors::Decryption
    report_undecryptable_google_token
    nil
  end

  # Wipe stored Google credentials (e.g. after the refresh token is revoked).
  def disconnect_google!
    update!(
      google_refresh_token:    nil,
      google_access_token:     nil,
      google_token_expires_at: nil,
      google_email:            nil,
      google_connected_at:     nil
    )
  end

  # Loud, once per occurrence: an undecryptable token means the encryption keys
  # changed under a live database, and the only fix is restoring them from a
  # backup (see docs/ENCRYPTION_KEYS.md). Degrading quietly would hide that.
  def report_undecryptable_google_token
    ErrorReporting.report(
      "User#google_token",
      ActiveRecord::Encryption::Errors::Decryption.new(
        "stored Google token could not be decrypted — ACTIVE_RECORD_ENCRYPTION_* " \
        "no longer match the keys the data was written with (see docs/ENCRYPTION_KEYS.md)"
      ),
      user_id: id
    )
  end

  # Powers PasswordsController + PasswordsMailer. The salt fragment in the
  # block invalidates outstanding reset links the moment a password is
  # changed, so a leaked old link can't be reused.
  generates_token_for :password_reset, expires_in: 15.minutes do
    password_salt&.last(10)
  end

  # Powers PartnershipAccountsController + PartnerAccountSetupsController: an
  # owner-created partner account has a random, discarded password until the
  # partner follows the emailed link to set their own. A week (vs. the 15
  # minutes above) gives them realistic time to check email.
  generates_token_for :account_setup, expires_in: 7.days do
    password_salt&.last(10)
  end

  # ── Email verification & terms (P0-8) ──────────────────────────────────────

  # A week, matching :account_setup — long enough that an email sitting unread
  # over a holiday still works. Keyed to the address itself, so changing the
  # email invalidates any outstanding link for the old one.
  generates_token_for :email_confirmation, expires_in: 7.days do
    email_address
  end

  def email_verified?
    email_verified_at.present?
  end

  def verify_email!
    update!(email_verified_at: Time.current) unless email_verified?
  end

  def accepted_terms?
    terms_accepted_at.present?
  end
end
