# A responder's anonymous name on one Verto ("Clever Axolotl") — the label the
# export's Responder column and the results page's Responders card group by.
# Sibling of PlayerAlias with the same written-once, derived-not-drawn
# contract, keyed on responses.respondent_code_digest rather than the
# leaderboard's browser identity. Deliberately a separate table: the two
# digest kinds are unlinkable identities, and erasure purges each by its own
# kind (RespondentDataController#destroy).
class RespondentAlias < ApplicationRecord
  belongs_to :survey

  validates :code_digest, :anon_name, presence: true

  MAX_NAME_ATTEMPTS = PlayerAlias::MAX_NAME_ATTEMPTS

  # Idempotent identity→name assignment — PlayerAlias.ensure_for!'s shape and
  # race reasoning (unique [survey_id, code_digest] turns the race into
  # RecordNotUnique; first writer wins), with one extra rule: a candidate
  # already naming a PLAYER on this Verto is skipped, one indexed lookup per
  # attempt. The export shows Responder and Device group side by side, and one
  # name in both columns would read as the same person when the identities are
  # deliberately unlinkable. One-directional on purpose: this path mints at
  # creator frequency (an export, a results view) and can afford the lookup,
  # while the player path mints on respondent submits and stays probe-free — a
  # player minted later taking an existing responder's name is the accepted
  # residual.
  def self.ensure_for!(survey:, code_digest:)
    existing = find_by(survey_id: survey.id, code_digest: code_digest)
    return existing if existing

    attempts = 0
    while attempts < MAX_NAME_ATTEMPTS
      candidate = PlayerAlias.derived_name_for(code_digest, attempts)
      if PlayerAlias.exists?(survey_id: survey.id, anon_name: candidate)
        attempts += 1
        next
      end
      begin
        return create!(survey: survey, code_digest: code_digest, anon_name: candidate)
      rescue ActiveRecord::RecordNotUnique
        winner = find_by(survey_id: survey.id, code_digest: code_digest)
        return winner if winner
        # The digest is free, so the collision was on anon_name — next candidate.
        attempts += 1
      end
    end
    raise ActiveRecord::RecordNotUnique,
          "no unused responder name for this Verto after #{MAX_NAME_ATTEMPTS} attempts"
  end
end
