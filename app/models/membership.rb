class Membership < ApplicationRecord
  belongs_to :user
  belongs_to :organisation

  # Three roles, in ascending order of what they may do:
  #
  #   viewer — shares Vertos and sees their results, and nothing else: no
  #            editor, no creation, no publish/unpublish, no settings. The
  #            role for a colleague who sends the link out and reads what
  #            comes back.
  #   member — creates and edits Vertos as well.
  #   admin  — also manages members, invites, the brand, partnerships and
  #            the account-level sharing decisions (named links, results
  #            links, Ask Verto opt-in).
  #
  # What each role is refused is enforced at the controller boundary
  # (OrganisationScope#require_admin!, #require_verto_editing!,
  # #require_verto_creation!) and mirrored by the view predicates that hide the
  # corresponding affordances (current_membership&.admin?, can_edit_vertos?,
  # can_create_vertos?). The database carries the same list as a CHECK
  # constraint (chk_memberships_role), so a value outside it fails loudly
  # whichever way it was written.
  ROLES = %w[viewer member admin].freeze

  enum :role, { viewer: "viewer", member: "member", admin: "admin" }

  # Everyone but a viewer: the roles that may open the editor and create.
  # Defined by exclusion, exactly as can_edit_vertos? is, so a fourth role
  # can't land in one and not the other.
  scope :editing, -> { where.not(role: "viewer") }

  # May this membership create or edit Vertos in its organisation? Admin and
  # member both can; viewer is the one that can't. The account-level creation
  # switch (Organisation#verto_creation_enabled) is a separate question, asked
  # by OrganisationScope#can_create_vertos?.
  def can_edit_vertos?
    !viewer?
  end
end
