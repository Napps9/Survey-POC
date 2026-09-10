require "test_helper"

# The door a respondent uses coming back on another device.
#
# PlayerAuthentication's header used to say there was deliberately no sign-in
# form anywhere, because the only way in was a link from an inbox. The join
# block takes a password now (owner's instruction, 2026-09-10), so this is the
# other half of that: the password has to be worth something on a device that
# never played the Verto.
class PlayerPasswordSignInTest < ActionDispatch::IntegrationTest
  PASSWORD = "correct-horse-battery"

  def player(password: PASSWORD, **attrs)
    Player.create!(email_address: "pp-#{SecureRandom.hex(4)}@test.com",
                   password: password, **attrs)
  end

  def sign_in(email, password)
    post new_player_session_path, params: { email_address: email, password: password }
  end

  # ── The form ──────────────────────────────────────────────────────────────

  test "the page renders for a signed-out visitor" do
    get new_player_session_path

    assert_response :success
    assert_select "input[type=email]"
    assert_select "input[type=password]"
  end

  test "a signed-in respondent is sent to their account rather than the form" do
    pl = player
    sign_in(pl.email_address, PASSWORD)

    get new_player_session_path

    assert_redirected_to you_path
  end

  # ── Signing in ────────────────────────────────────────────────────────────

  test "the right password starts a session" do
    pl = player

    assert_difference -> { PlayerSession.count }, 1 do
      sign_in(pl.email_address, PASSWORD)
    end

    assert_redirected_to you_path
    follow_redirect!
    assert_response :success
  end

  test "the address is matched as stored, whatever case it is typed in" do
    # Player normalises on write; the form must not be the one place that
    # forgets. dev/test are SQLite and production is Postgres and the two
    # disagree about LOWER() over a column, so this is done in Ruby.
    pl = player

    sign_in(pl.email_address.upcase, PASSWORD)

    assert_redirected_to you_path
  end

  test "a wrong password does not start a session" do
    pl = player

    assert_no_difference -> { PlayerSession.count } do
      sign_in(pl.email_address, "not-the-right-one")
    end

    assert_response :unauthorized
  end

  test "an unknown address and a wrong password read identically" do
    # The join endpoint had to give this distinction up to make signup work.
    # A bare sign-in form has no account to create, so it keeps it.
    pl = player

    sign_in(pl.email_address, "not-the-right-one")
    wrong = [ response.status, response.body ]

    sign_in("nobody-#{SecureRandom.hex(4)}@test.com", PASSWORD)

    assert_equal wrong.first, response.status
    assert_equal wrong.last, response.body,
                 "a form that answers differently for an address it knows confirms addresses"
  end

  test "a passwordless account cannot be signed into with any password" do
    # The shells Player.for_email left behind while the emailed link was the
    # only way in. authenticate returns false against a nil digest, but this
    # pins it: a bcrypt nil-digest regression would be a silent open door.
    shell = Player.for_email("shell-#{SecureRandom.hex(4)}@test.com")
    assert_nil shell.password_digest

    assert_no_difference -> { PlayerSession.count } do
      sign_in(shell.email_address, PASSWORD)
      sign_in(shell.email_address, "")
    end

    assert_response :unauthorized
  end

  # ── Signing in does not prove the address ─────────────────────────────────

  test "signing in with a password never marks the address verified" do
    # PlayerAudience.for_survey refuses to mail an unverified address, and only
    # a link out of an inbox proves one. A password proves the person chose it,
    # which is a different claim entirely.
    pl = player

    sign_in(pl.email_address, PASSWORD)

    assert_nil pl.reload.email_verified_at
  end

  # ── The recovery route ────────────────────────────────────────────────────

  test "the emailed link is still reachable and answers the same either way" do
    pl = player

    post player_session_link_path, params: { email_address: pl.email_address }
    known = [ response.status, response.location ]

    post player_session_link_path, params: { email_address: "nobody-#{SecureRandom.hex(4)}@test.com" }

    assert_equal known.first, response.status
    assert_equal known.last, response.location,
                 "there is no account to create here, so the oracle discipline still holds"
  end

  test "the link route mints and mails when the address is known" do
    pl = player

    assert_difference -> { PlayerSignInLink.count }, 1 do
      perform_enqueued_jobs do
        post player_session_link_path, params: { email_address: pl.email_address }
      end
    end

    assert_equal PlayerSignInLink::ORIGIN_EMAIL, PlayerSignInLink.last.origin,
                 "this one really is emailed, so spending it must verify the address"
  end

  test "no link is minted when mail cannot leave the building" do
    pl = player

    stub_method(MailConfigCheck, :deliverable?, ->(*) { false }) do
      assert_no_difference [ -> { PlayerSignInLink.count },
                             -> { ActionMailer::Base.deliveries.size } ] do
        post player_session_link_path, params: { email_address: pl.email_address }
      end
    end
  end

  # ── Routing ───────────────────────────────────────────────────────────────

  test "the email route is not swallowed by the token route" do
    # "email" is a legal :token, so post you/sign-in/email would otherwise land
    # in PlayerSignInsController and be answered as a spent link.
    assert_equal "player_sessions#link",
                 Rails.application.routes.recognize_path("/you/sign-in/email", method: :post)
                      .then { |r| "#{r[:controller]}##{r[:action]}" }
  end
end
