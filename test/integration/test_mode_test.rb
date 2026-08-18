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

  test "a test link still carries OpenGraph tags — it is built to be shared" do
    token = mint_token!
    delete session_path

    get test_survey_path(token)

    assert_response :success
    assert_select "meta[property='og:title'][content=?]", "Sports · Playverto"
    assert_select "meta[property='og:url'][content=?]", test_survey_url(token)
  end

  # ── Live Test Mode: /test/live/:token ──────────────────────────────────────
  #
  # Reached from the player's hidden press-and-hold hatch by whoever is holding
  # a LIVE play link. Everything above applies to it unchanged — that is the
  # point of routing it through the same render rather than a second one — so
  # these cover what is different: it takes a PLAY address, it insists the Verto
  # is actually live, and it offers a way back.

  def publish!
    @survey.update!(publish_token: SecureRandom.hex(8), published_at: Time.current)
    @survey.publish_token
  end

  test "a live play link can be played in Test Mode, with every endpoint blank" do
    token = publish!

    get live_test_survey_path(token)

    assert_response :success
    assert_select "[data-controller=player]" do |els|
      els.first.attributes.each do |name, attr|
        next unless name.end_with?("-url-value")
        assert_equal "", attr.value, "#{name} leaked a live endpoint into live Test Mode"
      end
    end
    assert_match I18n.t("player.test_mode_banner"), response.body
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
  end

  test "live Test Mode records nothing and never locks editing" do
    token = publish!

    get live_test_survey_path(token)

    assert_response :success
    assert_equal 0, @survey.reload.responses.count
    # published? already locks editing; the point is that playing this route
    # added no response of its own to lock it permanently.
    assert_equal 0, @survey.responses.count
  end

  test "it offers the way back to the very link the tester arrived on" do
    token = publish!

    get live_test_survey_path(token)

    assert_select "a.play-banner-link[href=?]", play_survey_path(token)
    assert_match I18n.t("player.exit_test_mode"), response.body
  end

  test "the creator's own /test link carries no exit — there is nowhere to go back to" do
    publish!
    test_token = mint_token!
    delete session_path

    get test_survey_path(test_token)

    assert_response :success
    assert_select "a.play-banner-link", 0
  end

  test "it resolves a named send link and a vanity slug, like the player itself" do
    publish!
    link = @survey.survey_links.create!(name: "Town hall", slug: "town-hall-#{SecureRandom.hex(2)}")
    get live_test_survey_path(link.slug)
    assert_response :success
    assert_select "a.play-banner-link[href=?]", play_survey_path(link.slug)

    @survey.update!(slug: "vanity-#{SecureRandom.hex(2)}")
    get live_test_survey_path(@survey.slug)
    assert_response :success
  end

  test "it needs a live Verto: unknown, draft, taken-down and deleted all refuse" do
    get live_test_survey_path("nope")
    assert_response :not_found

    # A draft has no play address at all, and its own test token is not one:
    # the two routes resolve by different keys and must not alias each other.
    draft_token = mint_token!
    delete session_path
    get live_test_survey_path(draft_token)
    assert_response :not_found

    token = publish!
    @survey.update!(unpublished_at: Time.current)
    get live_test_survey_path(token)
    assert_response :gone

    @survey.update!(unpublished_at: nil)
    @survey.archive!
    get live_test_survey_path(token)
    assert_response :gone
  end

  test "the live player carries the hatch, wired to its own live-test address" do
    token = publish!

    get play_survey_path(token)

    assert_response :success
    assert_select ".test-hatch-hotspot"
    assert_select "[data-player-test-mode-url-value=?]", live_test_survey_url(token)
  end

  test "neither Test Mode nor owner preview carries a working hatch" do
    publish!
    test_token = mint_token!
    delete session_path

    get test_survey_path(test_token)
    assert_response :success
    # The partial is skipped outright in preview/Test Mode, and the value it
    # would read is blank anyway — the "no live endpoint here" rule again.
    assert_select ".test-hatch-hotspot", 0
    assert_select "[data-player-test-mode-url-value='']"
  end

  test "the publish panel shows the test-link block" do
    mint_token!
    get survey_path(@survey)

    assert_response :success
    assert_match test_survey_url(@survey.test_token), response.body
    assert_match "Turn off test link", response.body
  end
end
