# A player's anonymous name on one Verto's leaderboard ("Clever Axolotl").
#
# One row per (survey, identity digest), written once and never updated — the
# name a respondent has seen is theirs for good, which is why there is no
# update path anywhere in the app. Uniqueness in both directions is enforced
# by the DB indexes: an identity has one name, and no two identities share a
# name on one board.
#
# Names are DERIVED from the identity digest, not drawn at random: the old
# draw-and-probe loop checked `exists?` per candidate and, past ~3,000 players
# (the full adjective×animal pool), degraded into an unbounded
# increment-and-probe scan — thousands of queries inside a request on a large
# board. Deriving from the digest needs no probe at all: the insert itself is
# the uniqueness check (the unique [survey_id, anon_name] index), and a
# collision just moves to the next deterministic candidate. Existing rows are
# untouched — a name is stored on assignment, never re-derived.
class PlayerAlias < ApplicationRecord
  belongs_to :survey

  validates :key_digest, :anon_name, presence: true

  # Bound on insert attempts. Attempt 0 is the plain "Adjective Animal" pair;
  # every later attempt appends a digest-derived number, giving ~31M
  # combinations per attempt — at 50,000 players on one board a given attempt
  # collides with probability ~0.2%, so two attempts is already the practical
  # worst case and twelve is a deep safety margin.
  MAX_NAME_ATTEMPTS = 12

  # Idempotent identity→name assignment. Safe to call from concurrent requests:
  # the unique [survey_id, key_digest] index makes the race a RecordNotUnique,
  # and whoever inserted first wins — the loser reads the winner's row. A name
  # collision (this candidate already on the board) moves to the next
  # deterministic candidate instead.
  def self.ensure_for!(survey:, key_digest:)
    existing = find_by(survey_id: survey.id, key_digest: key_digest)
    return existing if existing

    attempts = 0
    begin
      create!(survey: survey, key_digest: key_digest,
              anon_name: derived_name_for(key_digest, attempts))
    rescue ActiveRecord::RecordNotUnique
      winner = find_by(survey_id: survey.id, key_digest: key_digest)
      return winner if winner
      # The digest is free, so the collision was on anon_name — next candidate.
      attempts += 1
      retry if attempts < MAX_NAME_ATTEMPTS
      raise
    end
  end

  # Deterministic (digest, attempt) → candidate name. The digest is already an
  # HMAC, but it's re-hashed with the attempt so each attempt is an independent
  # draw over the whole pool rather than a neighbour of the last one.
  def self.derived_name_for(key_digest, attempt = 0)
    seed = Digest::SHA256.hexdigest("#{key_digest}:#{attempt}").to_i(16)
    adjective = AnonNames::ADJECTIVES[seed % AnonNames::ADJECTIVES.length]
    animal    = AnonNames::ANIMALS[(seed / AnonNames::ADJECTIVES.length) % AnonNames::ANIMALS.length]
    name      = "#{adjective} #{animal}"
    # Numbered variants start at 2, same convention the old saturated-pool
    # fallback used ("Clever Axolotl 2").
    attempt.zero? ? name : "#{name} #{2 + (seed % 9_998)}"
  end
end
