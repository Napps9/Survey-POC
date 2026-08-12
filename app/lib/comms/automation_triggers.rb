# The VertoNow-native trigger vocabulary: each trigger resolves the subjects
# an automation could fire for, as [{ user:, anchor:, org_id: (org events) }].
# Anchors are the event's own timestamp — the idempotency key embeds them,
# so a subject fires once per event, and an event that can recur (inactivity
# after a return) re-fires on its new anchor.
#
# Two invariants across every trigger:
#   * only verified users (we never mail an unproven address);
#   * anchor >= automation.created_at — events that predate the automation
#     never fire (a new welcome sequence must not blast the whole backlog).
module Comms
  module AutomationTriggers
    module_function

    def subjects_for(automation)
      case automation.trigger_type
      when "user_signed_up"
        user_signed_up(automation)
      when "user_inactive"
        user_inactive(automation)
      when "first_verto_published"
        org_event(automation, Survey.where.not(published_at: nil)
                                    .group(:organisation_id).minimum(:published_at))
      when "first_response_received"
        org_event(automation, Response.joins(:survey)
                                      .group("surveys.organisation_id").minimum("responses.created_at"))
      else
        []
      end
    end

    # Anchor: the address was proven (email_verified_at) — "signed up" that
    # can actually be mailed.
    def user_signed_up(automation)
      User.where(email_verified_at: automation.created_at..).map do |u|
        { user: u, anchor: u.email_verified_at }
      end
    end

    # Anchor: last activity + N days. A user who returns gets a fresh
    # last-activity timestamp, so a later lapse produces a NEW anchor and a
    # new fire — that's the re-fire semantics, carried by the key.
    def user_inactive(automation)
      days = automation.params.is_a?(Hash) ? automation.params["inactive_days"].to_i : 0
      days = 30 unless days.positive?

      last_seen = Session.group(:user_id).maximum(:created_at)
      return [] if last_seen.empty?

      User.where.not(email_verified_at: nil).where(id: last_seen.keys).filter_map do |u|
        anchor = last_seen[u.id] + days.days
        next if anchor > Time.current || anchor < automation.created_at

        { user: u, anchor: anchor }
      end
    end

    # Org-anchored events fire for every (verified) member of the org, all
    # sharing the org's anchor.
    def org_event(automation, firsts)
      firsts = firsts.select { |_org_id, t| t >= automation.created_at }
      return [] if firsts.empty?

      out = []
      Membership.where(organisation_id: firsts.keys).includes(:user).find_each do |m|
        user = m.user
        next if user.email_verified_at.nil?

        out << { user: user, anchor: firsts[m.organisation_id], org_id: m.organisation_id }
      end
      out
    end
  end
end
