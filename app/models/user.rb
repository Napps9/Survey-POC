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

  # Powers PasswordsController + PasswordsMailer. The salt fragment in the
  # block invalidates outstanding reset links the moment a password is
  # changed, so a leaked old link can't be reused.
  generates_token_for :password_reset, expires_in: 15.minutes do
    password_salt&.last(10)
  end
end
