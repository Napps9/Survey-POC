# A player's anonymous name on one Verto's leaderboard ("Clever Axolotl").
#
# One row per (survey, identity digest), written once and never updated — the
# name a respondent has seen is theirs for good, which is why there is no
# update path anywhere in the app. Uniqueness in both directions is enforced
# by the DB indexes: an identity has one name, and no two identities share a
# name on one board.
class PlayerAlias < ApplicationRecord
  belongs_to :survey

  validates :key_digest, :anon_name, presence: true

  # How many random draws to spend on finding an untaken name before falling
  # back to a numbered variant. ~3,000 combinations mean the first collision
  # lands around 65-70 players (birthday math); a dozen draws absorbs boards
  # far past that, and the suffix keeps very large boards correct, if plainer.
  MAX_NAME_ATTEMPTS = 12

  # Idempotent identity→name assignment. Safe to call from concurrent requests:
  # the unique [survey_id, key_digest] index makes the race a RecordNotUnique,
  # and whoever inserted first wins — the loser reads the winner's row. A name
  # collision (two identities drawing the same name at once) retries with a
  # fresh draw instead.
  def self.ensure_for!(survey:, key_digest:)
    existing = find_by(survey_id: survey.id, key_digest: key_digest)
    return existing if existing

    attempts = 0
    begin
      create!(survey: survey, key_digest: key_digest, anon_name: fresh_name_for(survey))
    rescue ActiveRecord::RecordNotUnique
      winner = find_by(survey_id: survey.id, key_digest: key_digest)
      return winner if winner
      # The digest is free, so the collision was on anon_name — draw again.
      attempts += 1
      retry if attempts < MAX_NAME_ATTEMPTS
      raise
    end
  end

  # A name not yet on this survey's board: random draws first, then a numbered
  # variant ("Clever Axolotl 2") once the pool is effectively saturated.
  def self.fresh_name_for(survey)
    MAX_NAME_ATTEMPTS.times do
      candidate = AnonNames.sample
      return candidate unless exists?(survey_id: survey.id, anon_name: candidate)
    end
    base = AnonNames.sample
    n = 2
    n += 1 while exists?(survey_id: survey.id, anon_name: "#{base} #{n}")
    "#{base} #{n}"
  end
end
