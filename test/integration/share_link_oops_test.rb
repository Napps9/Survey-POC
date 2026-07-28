require "test_helper"

# A creator sometimes shares the wrong URL — the /surveys/:id editor address
# bar instead of the /play/:token link from Publish & share, or a /play link
# copied before publishing. Each dead-end shows a branded explainer that says
# to publish the Verto and share the /play link, never a login redirect or a
# bare error string.
class ShareLinkOopsTest < ActionDispatch::IntegrationTest
  PASSWORD = "verylongpassword"

  def create_user_with_org(suffix)
    user = User.create!(name: "U#{suffix}", email_address: "u-#{suffix}-#{SecureRandom.hex(2)}@test.com", password: PASSWORD)
    org  = Organisation.create!(name: "O#{suffix}", slug: "o#{suffix}-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    [ user, org ]
  end

  def create_survey(org)
    org.surveys.create!(
      title: "S", theme: "Sports", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "multiple_choice", "text" => "Pick", "options" => %w[a b] } ]
    )
  end

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: PASSWORD }
    follow_redirect! if response.redirect?
  end

  test "unauthenticated visit to an editor URL shows the branded private-link page, not a login redirect" do
    _user, org = create_user_with_org("a")
    survey = create_survey(org)

    get survey_path(survey)

    assert_response :not_found
    assert_select "h1", text: I18n.t("oops.private_link_title")
    assert_match I18n.t("oops.sign_in"), response.body
  end

  test "private-link page still lets the creator sign in and return to the editor" do
    user, org = create_user_with_org("b")
    survey = create_survey(org)

    get survey_path(survey)
    assert_response :not_found

    post session_path, params: { email_address: user.email_address, password: PASSWORD }
    assert_redirected_to survey_url(survey)
  end

  test "signed-in user from another organisation gets the branded page with a dashboard link" do
    _owner, org = create_user_with_org("c")
    survey = create_survey(org)
    outsider, _their_org = create_user_with_org("d")
    sign_in(outsider)

    get survey_path(survey)

    assert_response :not_found
    assert_select "h1", text: I18n.t("oops.private_link_title")
    assert_match I18n.t("oops.my_vertos"), response.body
  end

  test "the owner still reaches the editor normally" do
    user, org = create_user_with_org("e")
    survey = create_survey(org)
    sign_in(user)

    get survey_path(survey)
    assert_response :success
  end

  test "a play link that resolves nothing shows the branded publish-first page" do
    get play_survey_path("no-such-token")

    assert_response :not_found
    assert_select "h1", text: I18n.t("oops.unpublished_title")
    assert_match ERB::Util.html_escape(I18n.t("oops.unpublished_hint")), response.body
  end

  test "a play link to an archived Verto shows the branded gone page" do
    _user, org = create_user_with_org("f")
    survey = create_survey(org)
    survey.update!(publish_token: SecureRandom.hex(8))
    survey.archive!

    get play_survey_path(survey.publish_token)

    assert_response :gone
    assert_select "h1", text: I18n.t("oops.gone_title")
  end

  test "non-show editor actions keep redirecting to sign-in when unauthenticated" do
    _user, org = create_user_with_org("g")
    survey = create_survey(org)

    get survey_results_path(survey)
    assert_redirected_to new_session_path
  end
end
