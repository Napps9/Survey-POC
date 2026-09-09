# One Verto attached to one account — the only cross-Verto join in this app.
# See the migration for why it lives here and not on `responses`.
#
# Written when a sign-in link is spent, never when an address is merely typed:
# nothing is attached to an email until someone proves they can read it.
class PlayerClaim < ApplicationRecord
  belongs_to :player
  belongs_to :survey
  belongs_to :response

  # signup         — the run they had just finished when they gave the address
  # signed_in_play — a Verto played while already signed in (phase 2)
  # device_key     — an earlier Verto this device still held a durable key for
  SOURCES = %w[signup signed_in_play device_key].freeze
  validates :source, inclusion: { in: SOURCES }

  scope :newest_first, -> { order(claimed_at: :desc) }

  # Idempotent. The unique [player_id, response_id] index is what makes a
  # replayed link — or the same Verto claimed from a second device — a no-op
  # rather than a duplicate, and it is enforced by the database rather than by
  # a check-then-write that two requests could both pass.
  def self.claim!(player:, response:, source:)
    create!(player: player, survey_id: response.survey_id, response: response,
            claimed_at: Time.current, source: source)
  rescue ActiveRecord::RecordNotUnique
    find_by(player_id: player.id, response_id: response.id)
  end
end
