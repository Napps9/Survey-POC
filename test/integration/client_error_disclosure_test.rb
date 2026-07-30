require "test_helper"

# P1-16. Three separate disclosures, each small on its own:
#
#   * signup answered "Email address has already been taken", turning the form
#     into an account-existence oracle for anyone with a list of addresses;
#   * a few endpoints returned a raw exception message to the client, which can
#     carry a SQL fragment, a column name or a file path;
#   * sign-in didn't rotate the Rails session, so a session id planted before
#     authentication was the one that ended up authenticated.
class ClientErrorDisclosureTest < ActionDispatch::IntegrationTest
  def setup
    @org  = Organisation.create!(name: "O", slug: "cd-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "cd-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
  end

  def login
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  # ── Account enumeration ─────────────────────────────────────────────────

  test "signing up with an existing address does not confirm it exists" do
    post registrations_path, params: {
      name: "Someone Else", email_address: @user.email_address,
      password: "verylongpassword", password_confirmation: "verylongpassword",
      organisation_name: "Another Org", accept_terms: "1"
    }

    assert_response :unprocessable_entity
    assert_equal I18n.t("registrations.signup_failed"), flash[:alert]
    assert_not_includes response.body, "has already been taken"
  end

  test "the generic message does not vary with whether the account exists" do
    # An attacker distinguishing "taken" from any other rejection is all the
    # oracle needs, so the wording must not encode the answer.
    post registrations_path, params: {
      name: "A", email_address: @user.email_address.upcase,
      password: "verylongpassword", password_confirmation: "verylongpassword",
      organisation_name: "Org", accept_terms: "1"
    }
    taken_message = flash[:alert]

    assert_equal I18n.t("registrations.signup_failed"), taken_message
  end

  test "other validation problems stay specific and useful" do
    # Genericising everything would leave someone with a short password no idea
    # what to fix. Only the existence signal is withheld.
    post registrations_path, params: {
      name: "", email_address: "brand-new-#{SecureRandom.hex(3)}@test.com",
      password: "verylongpassword", password_confirmation: "verylongpassword",
      organisation_name: "Org", accept_terms: "1"
    }

    assert_response :unprocessable_entity
    assert_not_equal I18n.t("registrations.signup_failed"), flash[:alert]
    assert_match(/name/i, flash[:alert])
  end

  # ── Raw exception messages ──────────────────────────────────────────────

  test "a failed autosave does not return the exception message" do
    login
    survey = @org.surveys.create!(title: "T", theme: "Th", audience_age: "adults", key_insight: "k",
                                  default_locale: "en", locales: [ "en" ], cards: [])

    boom = ->(*, **) { raise ActiveRecord::StatementInvalid, "PG::UndefinedColumn: ERROR: column \"secret\" does not exist" }
    stub_method(Survey, :sanitize_cards_images!, boom) do
      patch survey_path(survey), params: { cards: [] }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal false, body["ok"]
    assert_not_includes body["error"].to_s, "PG::UndefinedColumn"
    assert_not_includes body["error"].to_s, "secret"
    assert body["error"].present?, "the client still needs something to show"
  end

  test "the remaining raw e.message sites are gone from the editor endpoints" do
    # A grep-style guard: these two actions rescue broadly, so it's easy for a
    # future edit to reintroduce `error: e.message`.
    source = File.read(Rails.root.join("app/controllers/surveys_controller.rb"))
    update_rescue = source[/def update\b.*?\n  end\n/m]
    render_rescue = source[/def render_card\b.*?\n  end\n/m]

    assert_no_match(/error: e\.message/, update_rescue.to_s)
    assert_no_match(/error: e\.message/, render_rescue.to_s)
  end

  # ── Session fixation ────────────────────────────────────────────────────

  test "signing in rotates the session" do
    # Visit a protected page first so a pre-auth session exists, then confirm
    # the id it carried is not the one that ends up authenticated.
    get survey_results_path(999_999)
    before = session.id.to_s

    login
    assert_not_equal before, session.id.to_s, "the session id must change at sign-in"
  end

  test "the post-login redirect target survives the rotation" do
    # The one key deliberately carried across reset_session — written before
    # authentication, read after it. A blanket reset would silently send
    # everyone to the dashboard instead of where they were going.
    survey = @org.surveys.create!(title: "T", theme: "Th", audience_age: "adults", key_insight: "k",
                                  default_locale: "en", locales: [ "en" ], cards: [])

    # SurveysController overrides request_authentication to render a branded
    # "private link" page (404) rather than redirecting — but it still records
    # where the visitor was going, which is the part that must survive.
    get survey_path(survey)
    assert_response :not_found

    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    assert_redirected_to survey_url(survey)
  end
end
