require "test_helper"

# Test Mode: /test/:token plays the full Verto — drafts included — without
# sign-in, records nothing, and keeps working while the creator edits. The
# single failure mode worth pinning hard is a live endpoint URL reaching the
# unauthenticated test page: every data-player-*-url-value must be blank.
class TestModeTest < ActionDispatch::IntegrationTest
  def setup
    @org  = Organisation.create!(name: "TM", slug: "tm-#{SecureRandom.hex(2)}")
    @user = User.create!(name: "U", email_address: "tm-#{SecureRandom.hex(2)}@test.com",
                         password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "S", theme: "Sports", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "hi" },
               { "type" => "multiple_choice", "text" => "Pick", "options" => %w[a b] } ]
    )
  end

  def login
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
  end

  def mint_token!
    login
    post test_link_survey_path(@survey)
    @survey.reload.test_token.tap { |t| assert t.present?, "minting must store a token" }
  end

  test "an unauthenticated tester can play a DRAFT via the test link, with every endpoint blank" do
    token = mint_token!
    delete session_path # sign out — the whole point is no sign-in

    get test_survey_path(token)

    assert_response :success
    assert_select "[data-controller=player]" do |els|
      els.first.attributes.each do |name, attr|
        next unless name.end_with?("-url-value")
        assert_equal "", attr.value, "#{name} leaked a live endpoint into Test Mode"
      end
    end
    assert_match I18n.t("player.test_mode_banner"), response.body
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
  end

  test "the test link works for a published Verto too, still recording nothing" do
    @survey.update!(publish_token: SecureRandom.hex(8))
    token = mint_token!
    delete session_path

    get test_survey_path(token)

    assert_response :success
    assert_select "[data-player-progress-url-value='']"
    assert_select "[data-player-submit-url-value='']"
  end

  test "playing a test link never locks editing" do
    token = mint_token!
    get test_survey_path(token)

    assert_response :success
    refute @survey.reload.editing_locked?,
           "Test Mode records nothing, so it can never flip the editing lock"
    assert_equal 0, @survey.responses.count
  end

  test "unknown, disabled and deleted tokens do not resolve" do
    get test_survey_path("nope")
    assert_response :not_found

    token = mint_token!
    delete test_link_survey_path(@survey)
    assert_nil @survey.reload.test_token
    get test_survey_path(token)
    assert_response :not_found

    token = mint_token!
    @survey.archive!
    get test_survey_path(token)
    assert_response :gone
  end

  test "regenerating invalidates the old link" do
    old_token = mint_token!
    post test_link_survey_path(@survey)
    new_token = @survey.reload.test_token

    refute_equal old_token, new_token
    get test_survey_path(old_token)
    assert_response :not_found
    get test_survey_path(new_token)
    assert_response :success
  end

  test "only the owning organisation can mint or disable a test link" do
    other = User.create!(name: "O", email_address: "o-#{SecureRandom.hex(2)}@test.com",
                         password: "verylongpassword")
    Organisation.create!(name: "Other", slug: "oth-#{SecureRandom.hex(2)}")
                .memberships.create!(user: other, role: "admin")
    post session_path, params: { email_address: other.email_address, password: "verylongpassword" }

    post test_link_survey_path(@survey)
    assert_response :not_found
    assert_nil @survey.reload.test_token
  end

  test "minting needs no verified email, unlike publish" do
    refute @user.email_verified?
    mint_token!

    post publish_survey_path(@survey)
    assert_redirected_to survey_path(@survey)
    refute @survey.reload.published?, "publish stays gated on verification"
    assert @survey.test_token.present?, "the test link is not"
  end

  test "the publish panel shows the test-link block" do
    mint_token!
    get survey_path(@survey)

    assert_response :success
    assert_match test_survey_url(@survey.test_token), response.body
    assert_match "Turn off test link", response.body
  end
end
