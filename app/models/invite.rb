class Invite < ApplicationRecord
  belongs_to :organisation
  belongs_to :invited_by, class_name: "User"

  enum :kind, { member: "member", partner: "partner" }

  before_create { self.token = SecureRandom.urlsafe_base64(24) }

  scope :pending, -> { where(accepted_at: nil).where("expires_at > ?", Time.current) }

  def accepted? = accepted_at.present?
  def expired?  = expires_at < Time.current
  def pending?  = !accepted? && !expired?

  def addressed_email
    return nil if email_address.blank?
    return nil if email_address.end_with?("@partner.invite")
    email_address
  end
end
