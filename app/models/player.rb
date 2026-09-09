# A respondent's account. See db/migrate/…_create_players.rb for why this is
# not the creator `User` and why there is no password column.
class Player < ApplicationRecord
  has_many :player_sessions,      dependent: :destroy
  has_many :player_sign_in_links, dependent: :delete_all
  has_many :player_claims,        dependent: :delete_all
  has_many :claimed_surveys, -> { distinct }, through: :player_claims, source: :survey

  validates :email_address, presence: true, uniqueness: { case_sensitive: false },
                            format: { with: URI::MailTo::EMAIL_REGEXP }

  # Same normaliser as User. The column is compared and looked up as stored:
  # dev/test are SQLite and production is Postgres, and the two disagree about
  # LOWER() over a column, so the lowercasing happens in Ruby exactly once.
  normalizes :email_address, with: ->(e) { e.to_s.strip.downcase }

  # Longest address the join field will take. RFC 5321 allows 254; anything
  # longer is a paste accident or an attempt to make the index work.
  MAX_EMAIL = 254

  def email_verified? = email_verified_at.present?

  # Stamped the first time someone follows a link from their own inbox, which
  # is the only proof this app ever has that the address belongs to them.
  # Idempotent: a second sign-in must not move the date.
  def verify_email!
    update_column(:email_verified_at, Time.current) unless email_verified?
  end

  # Find-or-create by address. Deliberately does NOT say which it did: the join
  # endpoint's whole refusal discipline is that it never confirms whether an
  # address is already known (see PlayerController#join).
  def self.for_email(raw)
    email = raw.to_s.strip.downcase.first(MAX_EMAIL)
    return nil unless email.match?(URI::MailTo::EMAIL_REGEXP)

    find_or_create_by!(email_address: email)
  rescue ActiveRecord::RecordNotUnique
    # Two joins with the same address in the same instant; the loser reads the
    # winner's row, as PlayerAlias.ensure_for! does.
    find_by(email_address: email)
  end
end
