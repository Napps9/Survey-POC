# The single source of truth for who a campaign reaches. Resolves an
# audience definition (the campaign's `audience` json) into
# [{ email:, name:, user_id:, contact_id: }], with three invariants every
# caller inherits:
#
#   * emails are normalized and deduplicated (first occurrence wins);
#   * suppressed addresses (unsubscribed / bounced / complained / manual)
#     are subtracted HERE, so the count shown before Send is the number
#     actually mailed;
#   * platform users with an unverified address are never included — we
#     don't mail an address nobody proved they own (WelcomeMailer's rule).
#
# Kinds: {"kind":"all_users"}
#        {"kind":"organisations","organisation_ids":[..],"role":"any"|"admin"}
#        {"kind":"users","emails":[..]} (or "user_ids":[..])
#        {"kind":"list","list_id":N}
#
# A malformed or unknown definition resolves to EMPTY — never to everyone.
# (Temple collapsed junk to all-members; here a corrupted definition would
# mean mailing the whole platform, so the failure mode flips.)
module Comms
  module AudienceResolver
    module_function

    def resolve(definition)
      candidates = candidates_for(definition)
      return [] if candidates.empty?

      seen = {}
      candidates.each do |c|
        email = Comms.normalize_email(c[:email])
        next if email.blank? || seen.key?(email)

        seen[email] = { email: email, name: c[:name].to_s, user_id: c[:user_id], contact_id: c[:contact_id] }
      end

      suppressed = EmailSuppression.where(email: seen.keys).pluck(:email)
      suppressed.each { |email| seen.delete(email) }
      seen.values
    end

    def count(definition)
      resolve(definition).size
    end

    def candidates_for(definition)
      definition = {} unless definition.is_a?(Hash)
      case definition["kind"]
      when "all_users"
        verified_users(User.all)
      when "organisations"
        ids = Array(definition["organisation_ids"]).filter_map { |v| Integer(v, exception: false) }
        return [] if ids.empty?

        scope = User.joins(:memberships).where(memberships: { organisation_id: ids })
        scope = scope.where(memberships: { role: "admin" }) if definition["role"] == "admin"
        verified_users(scope)
      when "users"
        if definition["emails"].is_a?(Array)
          emails = definition["emails"].map { |e| Comms.normalize_email(e) }.reject(&:blank?)
          return [] if emails.empty?

          verified_users(User.where(email_address: emails))
        else
          ids = Array(definition["user_ids"]).filter_map { |v| Integer(v, exception: false) }
          return [] if ids.empty?

          verified_users(User.where(id: ids))
        end
      when "list"
        list_id = Integer(definition["list_id"], exception: false)
        return [] unless list_id

        EmailListContact.where(email_list_id: list_id).limit(20_000).map do |c|
          { email: c.email, name: c.name, user_id: nil, contact_id: c.id }
        end
      else
        []
      end
    end

    def verified_users(scope)
      scope.where.not(email_verified_at: nil).select(:id, :email_address, :name).map do |u|
        { email: u.email_address, name: u.name, user_id: u.id, contact_id: nil }
      end
    end
  end
end
