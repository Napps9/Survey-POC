require "test_helper"

# The account page. Three things it has to get right, all of them consequences
# of this being the first durable respondent handle the app has ever had:
# signed out is a page rather than a redirect (there is no sign-in form to send
# anyone to), the Vertos listed are only ever this account's own, and deleting
# the account takes the account — never the creator's research data.
class YouAccountTest < ActionDispatch::IntegrationTest
  def org = Organisation.create!(name: "O", slug: "you-#{SecureRandom.hex(3)}")

  def survey(owner: nil, **attrs)
    (owner || org).surveys.create!(
      title: "T", theme: "Car-free High Street", audience_age: "all",
      key_insight: "x", default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current, **attrs)
  end

  def sign_in_as(pl, claims = [])
    _link, raw = PlayerSignInLink.mint!(player: pl, claim_payload: claims)
    post player_sign_in_path(raw)
  end

  def player = Player.for_email("you-#{SecureRandom.hex(4)}@test.com")

  test "signed out, the page explains where a link comes from" do
    get you_path

    assert_response :success
    assert_select "h1.you-h1"
    # There is no sign-in form anywhere in this app — the only way in is a link
    # emailed from the end of a Verto — so the page must not offer one.
    assert_select "input[type=?]", "password", false
    assert_select ".you-verto", 0
  end

  test "the page is never written to a shared browser's disk cache" do
    get you_path
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "signed in, it lists the Vertos kept with their own token piles" do
    s = survey(tokenisation_enabled: true,
               token_types: [ { "id" => "leaf", "name" => "Leaves", "icon" => "🍃" } ])
    r = s.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true,
                            completed_at: 2.days.ago, token_totals: { "leaf" => 7 })
    pl = player
    sign_in_as(pl, [ { "response_id" => r.id, "source" => "signup" } ])

    get you_path

    assert_response :success
    assert_select ".you-verto", 1
    assert_select ".you-verto-title", text: "Car-free High Street"
    assert_select ".you-pile", text: /🍃\s*7\s*Leaves/
  end

  test "one account never sees another's Vertos" do
    o = org
    mine   = survey(owner: o)
    theirs = survey(owner: o)
    my_run    = mine.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true)
    their_run = theirs.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true)

    them = player
    PlayerClaim.claim!(player: them, response: their_run, source: "signup")

    me = player
    sign_in_as(me, [ { "response_id" => my_run.id, "source" => "signup" } ])
    get you_path

    assert_select ".you-verto", 1
    assert_select ".you-verto-title", text: "Car-free High Street"
    assert_equal 1, me.player_claims.count
  end

  test "a deleted Verto drops off the list rather than blanking the page" do
    s = survey
    r = s.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true)
    pl = player
    sign_in_as(pl, [ { "response_id" => r.id, "source" => "signup" } ])
    s.update_column(:deleted_at, Time.current)

    get you_path

    assert_response :success
    assert_select ".you-verto", 0
  end

  test "signing out ends the session and leaves the account alone" do
    pl = player
    sign_in_as(pl)

    post you_sign_out_path

    assert_redirected_to you_path
    assert Player.exists?(pl.id)
    assert_equal 0, pl.player_sessions.count
  end

  # ── Erasure stops where this person's authority stops ─────────────────────

  test "deleting the account takes the account, never the answers" do
    s = survey
    r = s.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true)
    pl = player
    sign_in_as(pl, [ { "response_id" => r.id, "source" => "signup" } ])
    PlayerSignInLink.mint!(player: pl)

    assert_difference -> { Player.count }, -1 do
      assert_no_difference -> { Response.count } do
        delete you_path
      end
    end

    assert_redirected_to you_path
    assert_equal 0, PlayerClaim.where(player_id: pl.id).count
    assert_equal 0, PlayerSignInLink.where(player_id: pl.id).count
    assert_equal 0, PlayerSession.where(player_id: pl.id).count
    assert r.reload.persisted?, "the pseudonymous response is the creator's research data"
  end

  test "the account pages are kept out of search results" do
    get you_path
    assert_match(/noindex/, response.headers["X-Robots-Tag"].to_s)
  end
end
