require "test_helper"

# Send links: the dashboard's Send modal and the named /play/ addresses it
# manages. The interesting half is the per-link override — the reason the
# feature exists is that one audience should be able to see how everyone else
# answered while another can't, so the tests below check BOTH the page and the
# endpoint that would otherwise hand the aggregate over anyway.
class SendLinksTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "title" => "hi" },
    { "type" => "yes_no", "text" => "Q", "options" => [ "Yes", "No" ] }
  ].freeze

  def sign_in_org(suffix, role: "admin")
    user = User.create!(name: "U", email_address: "sl-#{suffix}-#{SecureRandom.hex(2)}@test.com",
                        password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "sl-#{suffix}-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: role)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
    org
  end

  def published_survey(org, **attrs)
    org.surveys.create!({ title: "T", theme: "T", audience_age: "all", key_insight: "x",
                          default_locale: "en", locales: [ "en" ], cards: CARDS,
                          publish_token: SecureRandom.urlsafe_base64(18),
                          published_at: Time.current }.merge(attrs))
  end

  # ── The dashboard CTA ─────────────────────────────────────────────────────

  test "a live Verto's card leads with Send, a draft's does not" do
    org = sign_in_org("cta")
    published_survey(org, title: "Live one")
    org.surveys.create!(title: "Draft one", theme: "T", audience_age: "all", key_insight: "x",
                        default_locale: "en", locales: [ "en" ], cards: CARDS)

    get root_path
    assert_response :success
    assert_select "button[data-action='click->send-modal#open']", 1
    assert_select "[data-send-modal-target='modal']", 1
  end

  test "a non-admin member gets no Send button and no panel" do
    org = sign_in_org("member", role: "member")
    survey = published_survey(org)

    get root_path
    assert_select "button[data-action='click->send-modal#open']", 0

    get send_survey_path(survey)
    assert_redirected_to root_path
  end

  # ── The panel ─────────────────────────────────────────────────────────────

  test "the Send panel renders inside the turbo frame with the live link" do
    org = sign_in_org("panel")
    survey = published_survey(org)

    get send_survey_path(survey)
    assert_response :success
    assert_select "turbo-frame#send-modal"
    assert_select "input#send-url-main[value=?]", play_survey_url(survey.publish_token)
  end

  test "the panel says a draft isn't live yet but still manages links" do
    org = sign_in_org("draft-panel")
    draft = org.surveys.create!(title: "D", theme: "T", audience_age: "all", key_insight: "x",
                                default_locale: "en", locales: [ "en" ], cards: CARDS)

    get send_survey_path(draft)
    assert_response :success
    assert_select ".send-notice__title"
    assert_select "input#send-url-main", 0
    assert_select "form[action=?]", survey_links_path(draft)
  end

  test "a Verto in another organisation is not reachable" do
    other = Organisation.create!(name: "X", slug: "sl-x-#{SecureRandom.hex(3)}")
    theirs = published_survey(other)
    sign_in_org("cross")

    get send_survey_path(theirs)
    assert_response :not_found
  end

  # ── Creating and editing links ────────────────────────────────────────────

  test "creating a link derives a slug from its name" do
    org = sign_in_org("create")
    survey = published_survey(org)

    post survey_links_path(survey), params: { name: "Control Group!" }
    assert_redirected_to send_survey_path(survey)
    link = survey.survey_links.sole
    assert_equal "Control Group!", link.name
    assert_equal "control-group", link.slug
    assert link.active?
    # Nothing pinned: the link follows the Verto until someone says otherwise.
    assert_nil link.show_results_comparison
  end

  test "a requested custom URL is used, and de-collided rather than rejected" do
    org = sign_in_org("collide")
    survey = published_survey(org)

    post survey_links_path(survey), params: { name: "A", slug: "newsletter" }
    post survey_links_path(survey), params: { name: "B", slug: "Newsletter" }

    slugs = survey.survey_links.ordered.pluck(:slug)
    assert_equal [ "newsletter", "newsletter-2" ], slugs
  end

  test "a link cannot claim a slug another Verto's publish token already holds" do
    org = sign_in_org("ns")
    other = published_survey(org)
    other.update_column(:publish_token, "already-lowercase-token")
    survey = published_survey(org)

    post survey_links_path(survey), params: { name: "N", slug: "already-lowercase-token" }
    assert_equal "already-lowercase-token-2", survey.survey_links.sole.slug
  end

  test "a Verto's own custom slug cannot take a send link's address" do
    org = sign_in_org("reverse-ns")
    survey = published_survey(org)
    other  = published_survey(org)
    other.survey_links.create!(name: "N", slug: "town-hall")

    post survey_settings_path(survey), params: { slug: "town-hall", return_to: "send" }
    assert_nil survey.reload.slug
    assert_includes response.headers["Location"], "slug_error=taken"
    assert_includes response.headers["Location"], "/send"
  end

  test "settings posted from the modal come back to the modal" do
    org = sign_in_org("return-to")
    survey = published_survey(org)

    post survey_settings_path(survey), params: { show_results_comparison: "1", return_to: "send" }
    assert_redirected_to send_survey_path(survey)
    assert survey.reload.show_results_comparison?
  end

  test "renaming a link leaves its address alone" do
    org = sign_in_org("rename")
    survey = published_survey(org)
    link = survey.survey_links.create!(name: "Old", slug: "keep-this")

    patch survey_link_path(survey, link), params: { name: "New name" }
    assert_equal "New name", link.reload.name
    assert_equal "keep-this", link.slug
  end

  test "a link's address can be changed deliberately, but not onto a taken one" do
    org = sign_in_org("readdress")
    survey = published_survey(org)
    link  = survey.survey_links.create!(name: "A", slug: "one")
    survey.survey_links.create!(name: "B", slug: "two")

    patch survey_link_path(survey, link), params: { slug: "One Two Three" }
    assert_equal "one-two-three", link.reload.slug

    patch survey_link_path(survey, link), params: { slug: "two" }
    assert_equal "one-two-three", link.reload.slug
    assert_includes response.headers["Location"], "link_error=taken"
  end

  test "the per-Verto link cap is enforced" do
    org = sign_in_org("cap")
    survey = published_survey(org)
    SurveyLink::MAX_PER_SURVEY.times { |i| survey.survey_links.create!(name: "L#{i}", slug: "cap-#{i}") }

    assert_no_difference -> { SurveyLink.count } do
      post survey_links_path(survey), params: { name: "One too many" }
    end
    assert_includes response.headers["Location"], "link_error=limit"
  end

  test "deleting a link keeps the responses collected through it" do
    org = sign_in_org("delete")
    survey = published_survey(org)
    link = survey.survey_links.create!(name: "A", slug: "gone-soon")
    resp = survey.responses.create!(session_token: SecureRandom.uuid, survey_link: link, answered: true)

    assert_difference -> { SurveyLink.count }, -1 do
      delete survey_link_path(survey, link)
    end
    assert_nil resp.reload.survey_link_id
    assert_equal survey.id, resp.survey_id
  end

  # ── The player ────────────────────────────────────────────────────────────

  test "the player resolves a Verto by a send link's slug" do
    org = sign_in_org("resolve")
    survey = published_survey(org)
    survey.survey_links.create!(name: "Newsletter", slug: "news-2026")

    get play_survey_path("news-2026")
    assert_response :success
    assert_select ".q-title", text: "Q"
  end

  test "a paused link stops resolving, for reads and writes alike" do
    org = sign_in_org("paused")
    survey = published_survey(org)
    link = survey.survey_links.create!(name: "Off", slug: "switched-off")

    patch survey_link_path(survey, link), params: { active: "0" }
    assert_not link.reload.active?

    get play_survey_path("switched-off")
    assert_response :not_found

    post progress_survey_path("switched-off"),
         params: { session_token: SecureRandom.uuid, answers: {} }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :not_found
  end

  test "a send link's slug does not reach an unpublished Verto" do
    org = sign_in_org("draft-link")
    draft = org.surveys.create!(title: "D", theme: "T", audience_age: "all", key_insight: "x",
                                default_locale: "en", locales: [ "en" ], cards: CARDS)
    draft.survey_links.create!(name: "Early", slug: "too-early")

    get play_survey_path("too-early")
    assert_response :gone
  end

  test "a respondent arriving on a link is attributed to it" do
    org = sign_in_org("attribute")
    survey = published_survey(org)
    link = survey.survey_links.create!(name: "Newsletter", slug: "attrib-me")

    post progress_survey_path("attrib-me"),
         params: { session_token: "tok-#{SecureRandom.hex(4)}", answers: { "1" => { "value" => "Yes" } } }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success
    assert_equal link.id, survey.responses.sole.survey_link_id
  end

  # ── The whole point: one link compares, another doesn't ───────────────────

  test "a link can turn comparison on where the Verto has it off" do
    org = sign_in_org("compare-on")
    survey = published_survey(org, show_results_comparison: false)
    survey.survey_links.create!(name: "Cohort", slug: "compare-yes", show_results_comparison: true)

    get play_survey_path(survey.publish_token)
    assert_select ".welcome-intake-compare", 0

    get play_survey_path("compare-yes")
    assert_select ".welcome-intake-compare", 1
  end

  test "a link can turn comparison off where the Verto has it on" do
    org = sign_in_org("compare-off")
    survey = published_survey(org, show_results_comparison: true)
    survey.survey_links.create!(name: "Control", slug: "compare-no", show_results_comparison: false)

    get play_survey_path(survey.publish_token)
    assert_select ".welcome-intake-compare", 1

    get play_survey_path("compare-no")
    assert_select ".welcome-intake-compare", 0
  end

  test "the results endpoint refuses a link that has comparison off" do
    org = sign_in_org("compare-endpoint")
    survey = published_survey(org, show_results_comparison: true)
    survey.survey_links.create!(name: "Control", slug: "no-peeking", show_results_comparison: false)
    Response::MIN_REGION_SAMPLE_SIZE.times do
      survey.responses.create!(session_token: SecureRandom.uuid, answered: true,
                               answers: { "1" => { "value" => "Yes" } })
    end

    get player_results_path(survey.publish_token)
    assert_response :success
    assert JSON.parse(response.body)["ok"]

    # Hiding the button would not be enough — the endpoint is reachable by hand.
    get player_results_path("no-peeking")
    assert_response :forbidden
  end

  test "a link with no override follows the Verto" do
    org = sign_in_org("inherit")
    survey = published_survey(org, show_results_comparison: true)
    survey.survey_links.create!(name: "Plain", slug: "follows-verto")

    get play_survey_path("follows-verto")
    assert_select ".welcome-intake-compare", 1

    survey.update!(show_results_comparison: false)
    get play_survey_path("follows-verto")
    assert_select ".welcome-intake-compare", 0
  end

  test "the share button and regions map can be overridden per link too" do
    org = sign_in_org("other-overrides")
    survey = published_survey(org, share_enabled: true, regions_enabled: true)
    survey.survey_links.create!(name: "Quiet", slug: "quiet-link",
                                share_enabled: false, regions_enabled: false)

    get play_survey_path(survey.publish_token)
    body = response.body
    assert_includes body, play_survey_url(survey.publish_token)
    assert_includes body, player_regions_url(survey.publish_token)

    get play_survey_path("quiet-link")
    assert_not_includes response.body, player_regions_url("quiet-link")
  end

  # ── QR ────────────────────────────────────────────────────────────────────

  test "a link gets its own downloadable QR code" do
    org = sign_in_org("qr")
    survey = published_survey(org)
    link = survey.survey_links.create!(name: "Poster", slug: "poster-link")

    get qr_survey_path(survey, link_id: link.id)
    assert_response :success
    assert_equal "image/svg+xml", response.media_type
    assert_includes response.headers["Content-Disposition"], "poster-link-qr.svg"
  end

  test "a draft's link has no QR to download" do
    org = sign_in_org("qr-draft")
    draft = org.surveys.create!(title: "D", theme: "T", audience_age: "all", key_insight: "x",
                                default_locale: "en", locales: [ "en" ], cards: CARDS)
    link = draft.survey_links.create!(name: "Poster", slug: "draft-poster")

    get qr_survey_path(draft, link_id: link.id)
    assert_response :not_found
  end
end
