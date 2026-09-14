require "test_helper"

# What a respondent's run is worth, parked for the length of a Google round
# trip. The row exists because the page that knows the claims cannot put them
# anywhere else — see the migration — so everything valuable about it is the
# discipline around the token, not the token itself.
class PlayerOauthHandoffTest < ActiveSupport::TestCase
  def payload = [ { "response_id" => 7, "source" => "signup" } ]

  test "mint returns a raw token that is not what gets stored" do
    handoff, raw = PlayerOauthHandoff.mint!(claim_payload: payload)

    assert raw.present?
    refute_equal raw, handoff.token_digest,
                 "the token itself must never be stored — a leaked row would be a working link"
    refute_includes handoff.token_digest, raw
    assert_equal payload, handoff.claim_payload
  end

  test "a live token finds its row and a wrong one finds nothing" do
    handoff, raw = PlayerOauthHandoff.mint!(claim_payload: payload)

    assert_equal handoff, PlayerOauthHandoff.find_live(raw)
    assert_nil PlayerOauthHandoff.find_live("#{raw}x")
    assert_nil PlayerOauthHandoff.find_live("")
    assert_nil PlayerOauthHandoff.find_live(nil)
  end

  test "an expired handoff is not live" do
    handoff, raw = PlayerOauthHandoff.mint!(claim_payload: payload)
    handoff.update_column(:expires_at, 1.second.ago)

    assert_nil PlayerOauthHandoff.find_live(raw)
  end

  test "it expires within the quarter hour it promises" do
    handoff, _raw = PlayerOauthHandoff.mint!(claim_payload: payload)

    assert_in_delta PlayerOauthHandoff::LIFETIME.from_now, handoff.expires_at, 5
    assert_operator PlayerOauthHandoff::LIFETIME, :<, PlayerSignInLink::LIFETIME,
                    "this one survives a consent screen, not an inbox — it should be the shorter of the two"
  end

  # Two tabs coming back from Google at the same moment. Exactly one may spend
  # the claims; the other must be told no rather than applying them twice.
  test "consume is single use" do
    handoff, raw = PlayerOauthHandoff.mint!(claim_payload: payload)

    assert handoff.consume!
    refute PlayerOauthHandoff.find(handoff.id).consume!,
           "a second spend must fail — the UPDATE's own WHERE is what makes that atomic"
    assert_nil PlayerOauthHandoff.find_live(raw), "a spent handoff is no longer live"
  end

  # The two token spaces must not be interchangeable. A sign-in link proves an
  # address and a handoff does not, so a token minted for one must never verify
  # as the other — that is the whole reason for a separate HMAC key.
  test "a handoff token does not verify as a sign-in link, or the reverse" do
    _handoff, handoff_raw = PlayerOauthHandoff.mint!(claim_payload: payload)
    player = Player.create!(email_address: "h-#{SecureRandom.hex(3)}@test.com")
    _link, link_raw = PlayerSignInLink.mint!(player: player)

    assert_nil PlayerSignInLink.find_live(handoff_raw)
    assert_nil PlayerOauthHandoff.find_live(link_raw)
    refute_equal PlayerSignInLink.digest(handoff_raw), PlayerOauthHandoff.digest(handoff_raw),
                 "the same token must hash differently in the two spaces"
  end

  test "a deleted Verto does not take the handoff with it" do
    org = Organisation.create!(name: "H", slug: "h-#{SecureRandom.hex(3)}")
    survey = org.surveys.create!(title: "T", theme: "T", audience_age: "adults",
                                 key_insight: "k", default_locale: "en", locales: [ "en" ], cards: [])
    handoff, raw = PlayerOauthHandoff.mint!(claim_payload: payload, survey: survey)

    survey.destroy!

    assert_equal handoff, PlayerOauthHandoff.find_live(raw),
                 "a Verto deleted mid-flight must not strand somebody halfway through signing up"
    assert_nil handoff.reload.survey_id
  end
end
