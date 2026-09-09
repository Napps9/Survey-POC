# One emailed sign-in link: minted by the join block, spent by the landing
# page. See the migration for why this is a row rather than
# `generates_token_for`.
#
# The token is returned once, at mint time, and never stored — only its
# digest. Same discipline as a respondent code: a leaked row cannot be turned
# back into a working link.
class PlayerSignInLink < ApplicationRecord
  belongs_to :player

  # Long enough to survive an inbox, short enough that a link left in a
  # forwarded email or a shared browser history stops working the same
  # morning. The confirm page says the number, so it is not a surprise.
  LIFETIME = 20.minutes

  # 32 bytes of randomness, urlsafe. Guessing is not the threat model — the
  # digest index is unique, so a collision is a retry, not a takeover — but
  # this is a bearer credential and it is sized like one.
  TOKEN_BYTES = 32

  scope :live, -> { where(consumed_at: nil).where(arel_table[:expires_at].gt(Time.current)) }

  # Returns [record, raw_token]. The caller mails the raw token and forgets it.
  def self.mint!(player:, claim_payload: [])
    raw = SecureRandom.urlsafe_base64(TOKEN_BYTES)
    record = create!(player: player, token_digest: digest(raw),
                     claim_payload: claim_payload, expires_at: LIFETIME.from_now)
    [ record, raw ]
  end

  def self.digest(raw)
    normalised = raw.to_s.strip
    return nil if normalised.blank?

    OpenSSL::HMAC.hexdigest("SHA256", hmac_key, normalised)
  end

  def self.find_live(raw)
    d = digest(raw)
    d ? live.find_by(token_digest: d) : nil
  end

  # Single use, atomically. Two taps on the same button race here, and exactly
  # one of them gets the row: the UPDATE's own WHERE is the lock, so the loser
  # sees 0 rows and is told the link has already been used rather than being
  # handed a second session.
  #
  # Not `update!` — that would read, check and write in three steps with a gap
  # in the middle wide enough for the second tap.
  def consume!
    self.class.where(id: id, consumed_at: nil).update_all(consumed_at: Time.current) == 1
  end

  def self.hmac_key
    Rails.application.key_generator.generate_key("player_sign_in_link", 32)
  end
  private_class_method :hmac_key
end
