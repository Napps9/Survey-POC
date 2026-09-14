require "test_helper"

# The account page behind the name in the corner of /you: a name, a password,
# a language, and which organisations may write. Four forms, each with its
# own way of failing, and one bar above them all.
#
# Two properties carry the file. The password rules run in the order the
# controller states them, so a typo in the confirmation never spends a guess
# against the current password; and the email toggles honour only the
# organisations this account holds a Verto from — an id from anywhere else is
# nothing, not an error.
class YouSettingsTest < ActionDispatch::IntegrationTest
  PASSWORD = "correct-horse-battery"

  def org(name = "Haverley") = Organisation.create!(name: name, slug: "ys-#{SecureRandom.hex(3)}")

  def survey(owner: nil, **attrs)
    (owner || org).surveys.create!(
      title: "T", theme: "Car-free High Street", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current, **attrs)
  end

  def played(s)
    s.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true,
                        completed_at: 1.day.ago)
  end

  def player(**attrs) = Player.create!(email_address: "ys-#{SecureRandom.hex(4)}@test.com", **attrs)

  # The emailed link: the ordinary door, and the one that verifies the address.
  def sign_in_with_link(pl, responses = [])
    _link, raw = PlayerSignInLink.mint!(
      player: pl, claim_payload: responses.map { |r| { "response_id" => r.id, "source" => "signup" } })
    post player_sign_in_path(raw)
    pl
  end

  # The password form: the door that proves nothing about the inbox.
  def sign_in_with_password(pl, password = PASSWORD)
    post new_player_session_path, params: { email_address: pl.email_address, password: password }
    pl
  end

  # ── The page ──────────────────────────────────────────────────────────────

  test "signed out, the settings page sends you to the page that explains what this is" do
    get you_account_path
    assert_redirected_to you_path
  end

  test "signed in, it draws the four panels and the address" do
    pl = sign_in_with_link(player)

    get you_account_path

    assert_response :success
    assert_select "section.you-panel", 4
    %w[profile password preferences delete].each { |id| assert_select "section.you-panel##{id}", 1 }
    assert_select ".you-input-ro-text", text: pl.email_address
    assert_select "form[action=?][method=post]", you_account_path
    assert_select "form[action=?]", you_account_password_path
    assert_select "form[action=?]", you_account_preferences_path
    assert_select "form[action=?] input[name=_method][value=delete]", you_path
    # The address is shown, never edited: no field carries it.
    assert_select "input[name=email_address]", 0
    # And no sign-out here — that is in the bar's menu.
    assert_select "#delete form[action=?]", you_sign_out_path, 0
  end

  test "the Verified tag is drawn only for an address someone has proved" do
    # The link proves the inbox; the password form deliberately does not.
    sign_in_with_link(player)
    get you_account_path
    assert_select ".you-tag.is-teal", text: /#{I18n.t("you.email_verified")}/

    post you_sign_out_path
    unproved = sign_in_with_password(player(password: PASSWORD))
    assert_nil unproved.reload.email_verified_at
    get you_account_path
    assert_select ".you-tag.is-teal", 0
  end

  test "the Google tag is drawn only for an account Google has signed into" do
    pl = sign_in_with_link(player)
    get you_account_path
    assert_select ".you-tag", text: /#{I18n.t("you.email_google")}/, count: 0

    # Exactly the row PlayerOauthSessionsController#locate_or_create_player! writes.
    pl.player_identities.create!(provider: "google_player", uid: "gp-#{SecureRandom.hex(3)}",
                                 email: pl.email_address)
    get you_account_path
    assert_select ".you-tag", text: /#{I18n.t("you.email_google")}/, count: 1
  end

  test "the settings page is never written to a shared browser's disk cache" do
    sign_in_with_link(player)

    get you_account_path

    assert_equal "no-store", response.headers["Cache-Control"]
    assert_match(/noindex/, response.headers["X-Robots-Tag"].to_s)
  end

  # ── Profile ───────────────────────────────────────────────────────────────

  test "the name is saved stripped, and a blank one is no name" do
    pl = sign_in_with_link(player)

    patch you_account_path, params: { name: "  Ren Oso  " }
    assert_redirected_to you_account_path
    assert_equal "Ren Oso", pl.reload.name
    follow_redirect!
    assert_select ".you-flash.is-notice", text: I18n.t("you.saved")
    assert_select "input[name=name][value=?]", "Ren Oso"

    patch you_account_path, params: { name: "   " }
    assert_nil pl.reload.name
  end

  test "a name over the cap is refused with the reason, and the page is re-drawn" do
    pl = sign_in_with_link(player)
    pl.update!(name: "Kept")

    patch you_account_path, params: { name: "x" * (Player::MAX_NAME + 1) }

    assert_response :unprocessable_entity
    assert_select ".you-flash.is-alert", text: /#{Player::MAX_NAME}/
    assert_select "section.you-panel", 4
    assert_equal "Kept", pl.reload.name
  end

  test "the bar calls the account by its name, or by its address until it has one" do
    pl = sign_in_with_link(player)

    get you_path
    assert_select ".you-account-name", text: pl.email_address
    assert_select ".you-account-btn .you-avatar", text: pl.email_address[0].upcase
    assert_select ".you-account-who-email", text: pl.email_address

    patch you_account_path, params: { name: "élodie" }

    get you_path
    assert_select ".you-account-name", text: "élodie"
    # One grapheme, upcased — an accented initial is the letter, not half of it.
    assert_select ".you-account-btn .you-avatar", text: "É"
    assert_select ".you-account-who-name", text: "élodie"
    # The address stays under the name: on a shared device WHICH account you
    # are in is the thing worth knowing.
    assert_select ".you-account-who-email", text: pl.email_address
  end

  test "the bar carries sign out as a form, and the list no longer carries delete" do
    sign_in_with_link(player)

    get you_path

    assert_select ".you-account-popover form[action=?] button", you_sign_out_path,
                  text: I18n.t("you.sign_out")
    assert_select ".you-account-popover a[href=?]", you_account_path, text: I18n.t("you.menu_account")
    assert_select ".you-account-popover a[href=?]", you_wallet_path
    assert_select "form[action=?] input[name=_method][value=delete]", you_path, 0
    assert_select ".you-foot", 0
  end

  # ── Sign in ───────────────────────────────────────────────────────────────

  test "an account with no password sets one without being asked for the old one" do
    pl = sign_in_with_link(player)
    assert_nil pl.password_digest

    get you_account_path
    assert_select "input[name=current_password]", 0
    assert_select ".you-panel-sub", text: I18n.t("you.signin_sub_none")

    patch you_account_password_path, params: { password: PASSWORD, password_confirmation: PASSWORD }

    assert_redirected_to you_account_path
    assert_equal I18n.t("you.password_set"), flash[:notice]
    assert pl.reload.authenticate(PASSWORD)

    get you_account_path
    assert_select "input[name=current_password]", 1
    assert_select ".you-panel-sub", text: I18n.t("you.signin_sub_has")
  end

  test "a short password, a mismatch, and a wrong current password are each named" do
    pl = sign_in_with_link(player(password: PASSWORD))

    patch you_account_password_path,
          params: { current_password: PASSWORD, password: "short", password_confirmation: "short" }
    assert_redirected_to you_account_path
    assert_equal I18n.t("you.password_short", min: Player::MIN_PASSWORD), flash[:alert]

    patch you_account_password_path,
          params: { current_password: PASSWORD, password: "new-password-one", password_confirmation: "new-password-two" }
    assert_equal I18n.t("you.password_mismatch"), flash[:alert]

    patch you_account_password_path,
          params: { current_password: "not-it-at-all", password: "new-password-one", password_confirmation: "new-password-one" }
    assert_equal I18n.t("you.password_wrong"), flash[:alert]

    # Nothing above moved the password.
    assert pl.reload.authenticate(PASSWORD)
    assert_not pl.authenticate("new-password-one")
  end

  test "changing the password takes effect on the sign-in form at once" do
    pl = sign_in_with_link(player(password: PASSWORD))
    fresh = "a-brand-new-password"

    patch you_account_password_path,
          params: { current_password: PASSWORD, password: fresh, password_confirmation: fresh }

    assert_redirected_to you_account_path
    assert_equal I18n.t("you.password_changed"), flash[:notice]

    post you_sign_out_path
    sign_in_with_password(pl, PASSWORD)
    assert_response :unauthorized

    sign_in_with_password(pl, fresh)
    assert_redirected_to you_path
  end

  # ── Preferences ───────────────────────────────────────────────────────────

  test "the language is saved on the account, in the cookie, and on the very next page" do
    pl = sign_in_with_link(player)

    patch you_account_preferences_path, params: { preferred_locale: "fr" }

    assert_redirected_to you_account_path
    assert_equal "fr", pl.reload.preferred_locale
    assert_equal "fr", cookies["locale"]
    follow_redirect!
    assert_response :success
    assert_select "html[lang=fr]"
    assert_select ".you-topbar-chip", text: I18n.t("you.back", locale: :fr)
    assert_select ".you-flash.is-notice", text: I18n.t("you.prefs_saved", locale: :fr)
  end

  test "the email toggles write and delete the refusal row, idempotently" do
    o = org
    pl = sign_in_with_link(player, [ played(survey(owner: o)) ])

    get you_account_path
    assert_select ".you-row", 1
    assert_select "input[type=checkbox][name=?][checked]", "emails[#{o.id}]"

    patch you_account_preferences_path, params: { emails: { o.id.to_s => "0" } }
    assert_redirected_to you_account_path
    assert PlayerEmailPreference.unsubscribed?(pl.id, o.id)
    stamped = PlayerEmailPreference.find_by(player_id: pl.id, organisation_id: o.id).unsubscribed_at

    # Pressing it twice must not move the date — the first refusal counts.
    patch you_account_preferences_path, params: { emails: { o.id.to_s => "0" } }
    assert_equal 1, PlayerEmailPreference.where(player_id: pl.id).count
    assert_equal stamped, PlayerEmailPreference.find_by(player_id: pl.id, organisation_id: o.id).unsubscribed_at

    get you_account_path
    assert_select "input[type=checkbox][name=?]:not([checked])", "emails[#{o.id}]"

    patch you_account_preferences_path, params: { emails: { o.id.to_s => "1" } }
    assert_not PlayerEmailPreference.unsubscribed?(pl.id, o.id)

    # Resubscribing where nothing was refused is a no-op, not a lookup failure.
    patch you_account_preferences_path, params: { emails: { o.id.to_s => "1" } }
    assert_redirected_to you_account_path
    assert_equal 0, PlayerEmailPreference.where(player_id: pl.id).count
  end

  test "an organisation the account holds no Verto from cannot be toggled" do
    held     = org("Held")
    stranger = org("Stranger")
    pl = sign_in_with_link(player, [ played(survey(owner: held)) ])

    patch you_account_preferences_path,
          params: { emails: { stranger.id.to_s => "0", "999999" => "0", held.id.to_s => "0" } }

    assert_redirected_to you_account_path
    assert_equal [ held.id ], PlayerEmailPreference.where(player_id: pl.id).pluck(:organisation_id)
  end

  test "with no Vertos there are no toggles, and the page says why" do
    sign_in_with_link(player)

    get you_account_path

    assert_select ".you-row", 0
    assert_select ".you-help", text: I18n.t("you.emails_none")
  end

  test "the corner language switch is saved on the account too" do
    # A respondent's corner switch used to be cookie-only, so the account's
    # emails went on arriving in the language of the Verto they first played.
    pl = sign_in_with_link(player)

    post locale_path(locale: "de"), headers: { "HTTP_REFERER" => you_path }

    assert_redirected_to you_path
    assert_equal "de", pl.reload.preferred_locale
    assert_equal "de", cookies["locale"]
  end

  # ── Delete ────────────────────────────────────────────────────────────────

  test "deleting from the account page takes the account and nothing else" do
    s = survey
    r = played(s)
    pl = sign_in_with_link(player, [ r ])

    assert_difference -> { Player.count }, -1 do
      assert_no_difference -> { Response.count } do
        delete you_path
      end
    end

    assert_redirected_to you_path
    assert_equal 0, PlayerClaim.where(player_id: pl.id).count
    assert r.reload.persisted?
  end
end
