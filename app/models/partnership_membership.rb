class PartnershipMembership < ApplicationRecord
  belongs_to :partnership
  belongs_to :organisation

  enum :status, { active: "active", pending: "pending", revoked: "revoked" }

  validate :different_from_creator

  private

  def different_from_creator
    return unless partnership && organisation_id == partnership.organisation_id
    errors.add(:organisation, "cannot be the partnership creator")
  end
end
