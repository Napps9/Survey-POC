require "test_helper"

# P0-8. Signup accepted any address with no proof it belonged to the person, so
# a Verto could be published — and start collecting respondents' birth dates and
# locations — under an address its owner never consented to.
#
# The gate is on PUBLISHING, not on sign-in. SMTP is optional in this deployment
# (config/initializers/mailer.rb only warns when SMTP_ADDRESS is unset), so a
# hard sign-in gate would lock every new customer out of the product the moment
# mail was misconfigured. These tests pin that choice in both directions:
# building stays open, publishing does not.
class EmailConfirmationTest < ActionDispatch::IntegrationTest
  def signup(accept_terms: "1", email: nil)
    email ||= "ec-#{SecureRandom.hex(3)}@test.com"
    post registrations_path, params: {
      name: "New User", email_address: email,
      password: "verylongpassword", password_confirmation: "verylongpassword",
      organisation_name: "Org #{SecureRandom.hex(3)}",
      accept_terms: accept_terms
    }.compact
    User.find_by(email_address: email)
  end

  def verified_user
    user = User.create!(name: "V", email_address: "v-#{SecureRandom.hex(3)}@test.com",
                        password: "verylongpassword")
    org = Organisation.create!(name: "O", slug: "ec-v-#{SecureRandom.hex(3)}")
    org.memberships.create!(user: user, role: "admin")
    user.verify_email!
    user
  end

  def login(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  # ── Terms acceptance ────────────────────────────────────────────────────

  test "signup records when the terms were accepted" do
    user = signup
    assert_not_nil user, "signup should have succeeded"
    assert user.accepted_terms?
    assert_in_delta Time.current, user.terms_accepted_at, 5.seconds
  end

  test "signup is refused without accepting the terms" do
    assert_no_difference -> { User.count } do
      signup(accept_terms: nil)
    end
    assert_response :unprocessable_entity
    assert_equal I18n.t("registrations.terms_required"), flash[:alert]
  end

  test "an unchecked box does not create a half-made account" do
    # The check runs before save on purpose — a refused signup must not leave a
    # user behind whose terms_accepted_at we'd later have to guess at.
    assert_no_difference [ -> { User.count }, -> { Organisation.count } ] do
      signup(accept_terms: "0")
    end
  end

  test "the signup form offers the checkbox and links both documents" do
    get new_registration_path
    assert_response :success
    assert_select "input[type=checkbox][name=accept_terms]", 1
    assert_select "a[href=?]", terms_path
    assert_select "a[href=?]", privacy_path
  end

  # ── Verification ────────────────────────────────────────────────────────

  test "a new signup starts unverified and is sent a confirmation email" do
    user = nil
    assert_enqueued_emails 1 do
      user = signup
    end
    assert_not user.email_verified?
  end

  test "following the emailed link verifies the address" do
    user = signup
    token = user.generate_token_for(:email_confirmation)

    get email_confirmation_path(token)
    assert_redirected_to root_path
    assert_equal I18n.t("email_confirmation.confirmed"), flash[:notice]
    assert user.reload.email_verified?
  end

  test "the link works without being signed in" do
    # People open these on a phone that isn't logged in; demanding a session
    # first would send them round a loop.
    user  = signup
    token = user.generate_token_for(:email_confirmation)
    delete session_path

    get email_confirmation_path(token)
    assert user.reload.email_verified?
  end

  test "a garbage or expired token is refused without a 500" do
    get email_confirmation_path("not-a-real-token")
    assert_redirected_to root_path
    assert_equal I18n.t("email_confirmation.invalid"), flash[:alert]
  end

  test "changing the email address invalidates an outstanding link" do
    # The token is keyed to the address, so a link mailed to the old one can't
    # verify the new one — which is the whole point of verifying at all.
    user  = signup
    token = user.generate_token_for(:email_confirmation)
    user.update!(email_address: "moved-#{SecureRandom.hex(3)}@test.com")

    get email_confirmation_path(token)
    assert_redirected_to root_path
    assert_equal I18n.t("email_confirmation.invalid"), flash[:alert]
    assert_not user.reload.email_verified?
  end

  test "one user's token cannot verify another user" do
    a = signup
    b = signup
    get email_confirmation_path(a.generate_token_for(:email_confirmation))

    assert a.reload.email_verified?
    assert_not b.reload.email_verified?
  end

  # ── The publish gate ────────────────────────────────────────────────────

  def survey_for(user)
    org = user.organisations.first ||
          Organisation.create!(name: "O", slug: "ec-#{SecureRandom.hex(3)}")
                      .tap { |o| o.memberships.create!(user: user, role: "admin") }
    org.surveys.create!(title: "T", theme: "Th", audience_age: "adults", key_insight: "k",
                        default_locale: "en", locales: [ "en" ],
                        cards: [ { "type" => "yes_no", "cid" => "c", "text" => "Q", "options" => %w[Yes No] } ])
  end

  test "an unverified user cannot publish" do
    user   = signup
    login(user)
    survey = survey_for(user)

    post publish_survey_path(survey)
    assert_redirected_to survey_path(survey)
    assert_equal I18n.t("email_confirmation.publish_blocked"), flash[:alert]
    assert_nil survey.reload.publish_token
  end

  test "an unverified user can still build" do
    # The deliberate half of the design: gating sign-in would lock people out of
    # the product entirely if SMTP were misconfigured.
    user   = signup
    login(user)
    survey = survey_for(user)

    get survey_path(survey)
    assert_response :success

    patch survey_path(survey), params: { title: "Renamed" }.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    assert_response :success
  end

  test "verifying unblocks publishing" do
    user   = signup
    login(user)
    survey = survey_for(user)

    get email_confirmation_path(user.generate_token_for(:email_confirmation))
    post publish_survey_path(survey)

    assert_not_nil survey.reload.publish_token
  end

  test "existing accounts were grandfathered, so they are not locked out" do
    # The migration backfills email_verified_at for accounts that predate this,
    # because retroactively blocking live customers to close a signup hole would
    # break the product for the people already using it.
    user   = verified_user
    login(user)
    survey = survey_for(user)

    post publish_survey_path(survey)
    assert_not_nil survey.reload.publish_token
  end

  # ── Resend ──────────────────────────────────────────────────────────────

  test "an unverified user can ask for another email" do
    user = signup
    login(user)

    assert_enqueued_emails 1 do
      post email_confirmations_path
    end
    assert_match(/#{Regexp.escape(user.email_address)}/, flash[:notice])
  end

  test "a verified user asking again is told so rather than re-sent" do
    user = verified_user
    login(user)

    assert_no_enqueued_emails do
      post email_confirmations_path
    end
    assert_equal I18n.t("email_confirmation.already_confirmed"), flash[:notice]
  end

  test "the banner appears only while unverified" do
    user = signup
    login(user)
    get root_path
    assert_select "form[action=?]", email_confirmations_path, 1

    user.verify_email!
    get root_path
    assert_select "form[action=?]", email_confirmations_path, 0
  end
end
