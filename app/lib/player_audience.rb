# Who may be told about a Verto, and why it is not Comms::AudienceResolver.
#
# The deck's first instinct was to widen that resolver, and it does not fit.
# Every non-list branch there emits `user_id:`, and email_campaign_recipients
# .user_id has NO foreign key — so a Player id in that slot would silently
# dereference to whatever User happens to hold it, and mail one person's news
# to another. Its `"list"` branch shows the right shape (user_id: nil,
# contact_id:), which is to say: a non-User recipient needs its own column and
# its own branch, and once it has both, the only thing left being shared is
# the word "audience".
#
# So this is the players' own resolver, holding the same three invariants the
# creator-facing one states in its header, because they are properties of
# mailing people rather than of that class:
#
#   * addresses are normalised and deduplicated;
#   * suppressed addresses are subtracted HERE, so the count a creator is
#     shown before pressing send is the number actually mailed;
#   * an address nobody has proved they own is never mailed.
#
# And one this app has never had before, which board H says is not optional:
#   * an opt-out from THIS organisation is honoured, separately from the
#     global one — see PlayerEmailPreference.
module PlayerAudience
  module_function

  # Players who kept `survey` and may still be written to about it.
  #
  # Ordered and batched by the caller; this returns the scope rather than the
  # rows, because a Verto with 1,284 respondents is an ordinary size here and
  # materialising them all to filter in Ruby is not.
  def for_survey(survey)
    kept = Player.where(id: PlayerClaim.where(survey_id: survey.id).select(:player_id))

    # Unproven addresses are never mailed. A player only becomes verified by
    # following a link from their own inbox, so this is the same rule
    # WelcomeMailer states and the same one Comms applies to users.
    kept = kept.where.not(email_verified_at: nil)

    # This organisation, specifically. The narrow opt-out is the whole reason
    # board H needed a new table.
    kept = kept.where.not(
      id: PlayerEmailPreference.where(organisation_id: survey.organisation_id).select(:player_id))

    # And the global one, which a respondent reaches through "stop all
    # Playverto emails" and which also carries hard bounces and complaints.
    # Compared on the normalised column both sides already store, so no
    # LOWER() has to run — dev/test are SQLite and production is Postgres and
    # the two disagree about that (see CLAUDE.md).
    kept.where.not(email_address: EmailSuppression.select(:email))
  end

  # Whether one player may be told, asked one at a time. The job claims a
  # notification row before it mails, and this is the check that goes with it —
  # the scope above narrows the work, this makes each send correct even if the
  # scope was built minutes ago.
  def deliverable?(player, survey)
    player.email_verified? &&
      !PlayerEmailPreference.unsubscribed?(player.id, survey.organisation_id) &&
      !EmailSuppression.exists?(email: player.email_address)
  end
end
