class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy

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

  def google_connected?
    google_refresh_token.present?
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

  # Powers PasswordsController + PasswordsMailer. The salt fragment in the
  # block invalidates outstanding reset links the moment a password is
  # changed, so a leaked old link can't be reused.
  generates_token_for :password_reset, expires_in: 15.minutes do
    password_salt&.last(10)
  end
end
