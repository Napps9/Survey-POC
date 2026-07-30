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

  # Defence in depth for P1-10. Every controller that creates an invite already
  # downcases first, and User carries the same declaration — which in Rails 8
  # normalises finder queries too, not just writes, so a lookup by
  # "Foo@Bar.com" already matches a stored "foo@bar.com". This makes the invite
  # side stop depending on each caller remembering, and means a `pending` lookup
  # can't miss an invite that was written through some future path that didn't.
  normalizes :email_address, with: ->(e) { e.strip.downcase }

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
