# A respondent's opt-out from ONE organisation's mail. See the migration for
# why this exists alongside the global EmailSuppression rather than instead of
# it.
#
# A row means "stop"; no row means they still hear from that organisation,
# which is what they asked for when they gave the address. Written only from a
# link in a mail we sent them.
class PlayerEmailPreference < ApplicationRecord
  belongs_to :player
  belongs_to :organisation

  # Idempotent, and race-safe on the unique index rather than on a
  # check-then-write two requests could both pass. Pressing unsubscribe twice
  # must not move the date — the first refusal is the one that counts.
  def self.unsubscribe!(player:, organisation:)
    create!(player: player, organisation: organisation, unsubscribed_at: Time.current)
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    find_by(player_id: player.id, organisation_id: organisation.id)
  end

  def self.unsubscribed?(player_id, organisation_id)
    exists?(player_id: player_id, organisation_id: organisation_id)
  end
end
