# Attaching the Vertos a sign-in was minted to attach.
#
# Lifted out of PlayerSignInsController the day a second thing started
# spending one of these: a Google handoff carries the same payload, made by the
# same join_claim_payload, and there is no version of "which runs belong to
# this person" that should differ by how they signed in.
#
# Every step is defensive, and deliberately. A response may have been erased
# between the join and the click, and a survey may have been deleted. A claim
# that cannot be made is skipped, never raised — the person is signing in, and
# the sign-in must not fail because one of their Vertos went away. A partial
# claim is better than a refused sign-in: they are in, and the missing Verto is
# recoverable by playing it again.
module PlayerClaimPayload
  def self.apply(player:, payload:, reporting_context: "PlayerClaimPayload.apply")
    Array(payload).each do |entry|
      next unless entry.is_a?(Hash)

      response = Response.find_by(id: entry["response_id"])
      next if response.nil?

      source = PlayerClaim::SOURCES.include?(entry["source"]) ? entry["source"] : "signup"
      PlayerClaim.claim!(player: player, response: response, source: source)
    end
  rescue => e
    ErrorReporting.report(reporting_context, e, player_id: player.id)
  end
end
