require "test_helper"

# The join endpoint and what it is allowed to hand out.
#
# Two properties carry this file. The first is that nothing is written against
# an address until someone proves they can read it — the join call parks a
# payload on a link and stops. The second is that every refusal looks like a
# success: unknown address, blank address, join switched off, a Verto that
# isn't yours. An endpoint that answers differently for an address it has seen
# before is an endpoint that confirms addresses.
class PlayerClaimsTest < ActionDispatch::IntegrationTest
  def org = Organisation.create!(name: "O", slug: "pc-#{SecureRandom.hex(3)}")

  def survey(owner: nil, join: true, **attrs)
    (owner || org).surveys.create!(
      title: "T", theme: "Car-free High Street", audience_age: "all",
      key_insight: "x", default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ],
      join_prompt_enabled: join,
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current, **attrs)
  end

  def completed(s, key: nil)
    s.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true,
                        player_key_digest: key ? s.player_key_digest(key) : nil)
  end

  def join(s, **payload)
    post join_survey_path(s.publish_token), params: payload.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
  end

  def address = "pc-#{SecureRandom.hex(4)}@test.com"

  # The raw token out of the email that was actually sent — the only place it
  # exists, since PlayerSignInLink stores nothing but its digest.
  def mailed_token
    mail = ActionMailer::Base.deliveries.last
    (mail.text_part || mail).body.to_s[%r{/you/sign-in/([\w\-]+)}, 1]
  end

  # The link the join just minted, and the claims parked on it.
  def payload_of(email)
    PlayerSignInLink.joins(:player).where(players: { email_address: email }).last&.claim_payload
  end

  # ── Nothing is written against an address that hasn't answered ────────────

  test "joining mints a link and claims nothing yet" do
    s = survey
    r = completed(s)
    email = address

    assert_difference -> { PlayerSignInLink.count }, 1 do
      assert_no_difference -> { PlayerClaim.count } do
        join(s, email: email, session_token: r.session_token)
      end
    end

    assert_response :success
    assert_equal({ "ok" => true }, JSON.parse(response.body))
    assert_equal [ r.id ], payload_of(email).map { |c| c["response_id"] }
  end

  test "the run just finished is claimed once the link is followed" do
    s = survey
    r = completed(s)
    email = address
    perform_enqueued_jobs { join(s, email: email, session_token: r.session_token) }

    post player_sign_in_path(mailed_token)

    claim = Player.find_by(email_address: email).player_claims.sole
    assert_equal r.id, claim.response_id
    assert_equal s.id, claim.survey_id
    assert_equal "signup", claim.source
  end

  # ── Device keys reach back to earlier Vertos, and only your own ───────────

  test "a device key claims that Verto's completed runs" do
    o = org
    first  = survey(owner: o)
    second = survey(owner: o)
    key    = SecureRandom.uuid
    earlier = completed(first, key: key)
    now     = completed(second)
    email   = address

    join(second, email: email, session_token: now.session_token,
                 device_keys: [ { token: first.publish_token, player_key: key } ])

    ids = payload_of(email).map { |c| c["response_id"] }
    assert_equal [ now.id, earlier.id ].sort, ids.sort
    assert_equal "device_key", payload_of(email).find { |c| c["response_id"] == earlier.id }["source"]
  end

  test "a key lifted from one Verto resolves to nothing on another" do
    o = org
    mine     = survey(owner: o)
    stranger = survey(owner: o)
    key      = SecureRandom.uuid
    # The key belongs to `mine`; the stranger's rows carry the SAME raw key,
    # digested under the stranger's own per-survey HMAC.
    completed(mine, key: key)
    theirs = completed(stranger, key: key)
    email  = address

    # Ask for the stranger's Verto with a key digested for `mine`.
    join(mine, email: email,
               device_keys: [ { token: stranger.publish_token, player_key: "#{key}-not-mine" } ])

    refute_includes payload_of(email).map { |c| c["response_id"] }, theirs.id
  end

  test "an unresolvable token is skipped, not fatal" do
    s = survey
    r = completed(s)
    email = address

    join(s, email: email, session_token: r.session_token,
            device_keys: [ { token: "no-such-verto", player_key: SecureRandom.uuid } ])

    assert_response :success
    assert_equal [ r.id ], payload_of(email).map { |c| c["response_id"] }
  end

  test "a session token from another Verto claims nothing" do
    o = org
    mine  = survey(owner: o)
    other = survey(owner: o)
    theirs = completed(other)
    email  = address

    join(mine, email: email, session_token: theirs.session_token)

    assert_empty payload_of(email)
  end

  # ── Idempotency ───────────────────────────────────────────────────────────

  test "following the same claim twice is a no-op" do
    s = survey
    r = completed(s)
    pl = Player.for_email(address)

    2.times do
      _link, raw = PlayerSignInLink.mint!(
        player: pl, claim_payload: [ { "response_id" => r.id, "source" => "signup" } ])
      post player_sign_in_path(raw)
    end

    assert_equal 1, pl.player_claims.count, "the unique index makes a replay a no-op"
  end

  # ── Every refusal is the success shape ────────────────────────────────────

  test "refusals are indistinguishable from a success" do
    s   = survey
    off = survey(join: false)
    r   = completed(s)
    ok  = { "ok" => true }

    # Joined for real.
    join(s, email: address, session_token: r.session_token)
    assert_equal ok, JSON.parse(response.body)

    # Switched off, blank, malformed, and an address nobody has ever used.
    [ [ off, address ], [ s, "" ], [ s, "not-an-address" ], [ s, address ] ].each do |verto, email|
      join(verto, email: email)
      assert_response :success
      assert_equal ok, JSON.parse(response.body), "#{email.inspect} on #{verto.id} must read as a success"
    end
  end

  test "a Verto with join switched off sends nothing and creates no player" do
    s = survey(join: false)
    email = address

    assert_no_difference [ -> { Player.count }, -> { PlayerSignInLink.count },
                           -> { ActionMailer::Base.deliveries.size } ] do
      join(s, email: email)
    end
    assert_response :success
  end

  test "a blank or malformed address creates nothing" do
    s = survey

    assert_no_difference [ -> { Player.count }, -> { PlayerSignInLink.count } ] do
      join(s, email: "")
      join(s, email: "nope")
      join(s, email: "two words@example.com")
    end
  end

  # ── The endpoint's shape ──────────────────────────────────────────────────

  test "join sets no cookie" do
    s = survey
    join(s, email: address)

    assert_nil cookies[:player_session_id].presence,
               "the join endpoint runs under null_session and can never set one"
  end

  test "join writes no player_key_digest onto the finished run" do
    # A digest written only for joiners would populate the creator's "Device
    # group" CSV column for exactly the people who opted in, and would let a
    # later leaderboard enable build a board out of joiners alone.
    s = survey
    r = completed(s)

    join(s, email: address, session_token: r.session_token,
            device_keys: [ { token: s.publish_token, player_key: SecureRandom.uuid } ])

    assert_nil r.reload.player_key_digest
  end

  test "an unknown play token is a 404, and a closed Verto is gone" do
    post join_survey_path("nope"), params: { email: address }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :not_found

    s = survey
    s.update_column(:unpublished_at, 1.hour.ago)
    join(s, email: address)
    assert_response :gone
  end

  test "the address is remembered as the account's locale on the first join only" do
    s = survey(locales: [ "en", "fr" ])
    email = address

    join(s, email: email, lang: "fr")
    assert_equal "fr", Player.find_by(email_address: email).preferred_locale

    join(s, email: email, lang: "en")
    assert_equal "fr", Player.find_by(email_address: email).preferred_locale,
                 "a later join must not move a preference the account already holds"
  end
end
