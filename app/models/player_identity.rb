# A respondent's linked provider account. See the migration for why this is
# not a row in `identities`.
class PlayerIdentity < ApplicationRecord
  belongs_to :player

  validates :provider, presence: true
  validates :uid, presence: true, uniqueness: { scope: :provider }

  # Same normaliser as Player and User. Stored lowercase so a provider that
  # changes its capitalisation between sign-ins does not look like a new
  # address — and because SQLite and Postgres disagree about LOWER() over a
  # column, which is why every comparison in this app is made in Ruby once.
  normalizes :email, with: ->(e) { e.to_s.strip.downcase.presence }
end
