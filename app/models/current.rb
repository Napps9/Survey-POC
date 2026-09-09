class Current < ActiveSupport::CurrentAttributes
  attribute :session, :organisation, :locale
  delegate :user, to: :session, allow_nil: true

  # The respondent's own identity, kept disjoint from the creator's on purpose.
  # OrganisationScope#set_current_organisation dereferences
  # Current.user.memberships with no nil guard, so a Player arriving through
  # Current.session would NoMethodError on its first request — and every
  # creator-facing scope in the app reads Current.user expecting a User.
  attribute :player_session
  delegate :player, to: :player_session, allow_nil: true
end
