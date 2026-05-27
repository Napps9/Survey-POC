class AllianceMembership < ApplicationRecord
  belongs_to :alliance
  belongs_to :organisation

  enum :status, { active: "active", pending: "pending", revoked: "revoked" }

  validate :different_from_creator

  private

  def different_from_creator
    return unless alliance && organisation_id == alliance.organisation_id
    errors.add(:organisation, "cannot be the alliance creator")
  end
end
