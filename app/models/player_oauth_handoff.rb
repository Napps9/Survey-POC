# One respondent's Google round trip. Minted by the player page's Continue
# with Google, spent by the callback. See the migration for why the claims
# travel in a row rather than in the session.
#
# Everything here is PlayerSignInLink's discipline applied to a row that has no
# player on it yet: digest-only storage, an atomic single use, and an expiry.
class PlayerOauthHandoff < ApplicationRecord
  belongs_to :survey, optional: true

  # Shorter than PlayerSignInLink's 20 minutes, and deliberately: that one has
  # to survive an inbox, this one has to survive a consent screen. Anything
  # left half-finished for longer than this is an abandoned tab, and the next
  # tap starts a fresh one at no cost to anybody.
  LIFETIME = 15.minutes

  # A bearer credential, sized like one. Guessing is not the threat model —
  # the digest index is unique — but a working token is a claim on somebody's
  # answers until it is spent.
  TOKEN_BYTES = 32

  scope :live, -> { where(consumed_at: nil).where(arel_table[:expires_at].gt(Time.current)) }

  # Returns [record, raw_token]. The caller hands the raw token to the browser
  # in the join response and forgets it.
  def self.mint!(claim_payload: [], survey: nil, locale: nil)
    raw = SecureRandom.urlsafe_base64(TOKEN_BYTES)
    record = create!(token_digest: digest(raw), claim_payload: claim_payload,
                     survey: survey, locale: locale.presence,
                     expires_at: LIFETIME.from_now)
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

  # Single use, atomically — the UPDATE's own WHERE is the lock, so two tabs
  # returning from Google at once cannot both spend the same claims. Not
  # `update!`, which would read, check and write with a gap in the middle.
  def consume!
    self.class.where(id: id, consumed_at: nil).update_all(consumed_at: Time.current) == 1
  end

  # Its own key, not PlayerSignInLink's. The two token spaces must not be
  # interchangeable: a sign-in link proves an address and this does not, so a
  # token minted here must never verify as one minted there.
  def self.hmac_key
    Rails.application.key_generator.generate_key("player_oauth_handoff", 32)
  end
  private_class_method :hmac_key
end
