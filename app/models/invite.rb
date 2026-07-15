class Invite < ApplicationRecord
  belongs_to :organisation
  belongs_to :invited_by, class_name: "User"
  belongs_to :partnership, optional: true
  belongs_to :funder, optional: true

  # "licensee" (not "funder") for the kind value — Invite.funder is the
  # belongs_to scope; an enum value of the same name would collide with it.
  enum :kind, { member: "member", partner: "partner", licensee: "licensee" }

  validates :partnership, presence: true, if: :partner?
  validates :funder, presence: true, if: :licensee?

  before_create { self.token = SecureRandom.urlsafe_base64(24) }

  scope :pending, -> { where(accepted_at: nil).where("expires_at > ?", Time.current) }

  def accepted? = accepted_at.present?
  def expired?  = expires_at < Time.current
  def pending?  = !accepted? && !expired?

  def addressed_email
    return nil if email_address.blank?
    return nil if email_address.end_with?("@partner.invite", "@funder.invite")
    email_address
  end
end
