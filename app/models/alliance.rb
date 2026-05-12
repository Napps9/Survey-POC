class Alliance < ApplicationRecord
  belongs_to :organisation
  belongs_to :partner_organisation, class_name: "Organisation"
  has_many :survey_shares, dependent: :destroy

  enum :status, { active: "active", pending: "pending", revoked: "revoked" }

  validate :different_organisations

  private

  def different_organisations
    return unless organisation_id && partner_organisation_id
    errors.add(:partner_organisation, "cannot be the same as the organisation") if organisation_id == partner_organisation_id
  end
end
