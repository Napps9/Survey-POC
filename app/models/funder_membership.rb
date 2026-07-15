class FunderMembership < ApplicationRecord
  belongs_to :funder
  belongs_to :organisation

  enum :status, { active: "active", suspended: "suspended" }

  validate :different_from_creator
  validate :seat_available, if: :active?

  # Activates (or reactivates) organisation's license under funder. Shared by
  # the invite-accept flow and the owner-creates-account flow so both end up
  # in the identical state.
  def self.assign!(funder:, organisation:)
    membership = find_or_initialize_by(funder: funder, organisation: organisation)
    membership.status = "active"
    membership.save!
    membership
  end

  # Frees the seat immediately without losing the membership's history, so it
  # can be handed to a different org or reactivated for this one later.
  def suspend!
    update!(status: "suspended")
  end

  def reactivate!
    update!(status: "active")
  end

  private

  def different_from_creator
    return unless funder && organisation_id == funder.organisation_id
    errors.add(:organisation, "cannot be the funder's own organisation")
  end

  def seat_available
    return unless funder
    active_count = funder.funder_memberships.active.where.not(id: id).count
    errors.add(:base, "No seats available") if active_count >= funder.seat_count
  end
end
