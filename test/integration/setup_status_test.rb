require "test_helper"

# An import hands its creator straight to the editor while FinishVertoSetupJob
# fills in imagery behind them. That's deliberate — they have already waited
# through the upload and the review screen — but for as long as it was invisible
# it was also destructive: the editor rebuilds every card from the DOM, the DOM
# had no pictures in it yet, and the first autosave wrote that emptiness over
# everything the job had just done. background_image survived (it's a column,
# and serialize() never sends it), which is why the report was "a background but
# blank cards" rather than "nothing happened".
#
# Two halves, both here: the endpoint the editor polls, and the server-side
# guard that covers the gap between one poll and the next.
class SetupStatusTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "ss-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "ss-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def survey(pending: true, cards: nil)
    @org.surveys.create!(
      title: "T", theme: "Sport", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      setup_pending_since: (pending ? Time.current : nil),
      cards: cards || [
        { "type" => "yes_no", "cid" => "c_1", "text" => "Q1", "options" => %w[Yes No],
          "image" => "/img/one.jpg", "image_credit" => "Bo", "subject" => "a runner" },
        { "type" => "yes_no", "cid" => "c_2", "text" => "Q2", "options" => %w[Yes No] }
      ]
    )
  end

  def body = JSON.parse(response.body)

  # ── The endpoint ───────────────────────────────────────────────────────────

  test "it reports the pending flag and every card that has media, keyed by cid" do
    s = survey
    get setup_status_survey_path(s)
    assert_response :success

    assert_equal true, body["pending"]
    assert_equal [ "c_1" ], body["cards"].map { |c| c["cid"] },
                 "a card with nothing on it yet has nothing to say — it must not appear"

    card = body["cards"].first
    assert_equal "/img/one.jpg", card["image"]
    assert_equal "Bo", card["image_credit"]
    assert_equal "a runner", card["subject"],
                 "subject renders nowhere, which is exactly why it gets forgotten — " \
                 "serialize() emits it, so the client has to be told about it or the " \
                 "next autosave strips what CardSubjectExtractor paid Claude for"
  end

  test "it stops reporting pending once the job has cleared the flag" do
    s = survey(pending: false)
    get setup_status_survey_path(s)
    assert_response :success
    assert_equal false, body["pending"]
  end

  test "a stale flag reads as finished rather than pending forever" do
    s = survey
    s.update!(setup_pending_since: Survey::SETUP_STALE_AFTER.ago - 1.minute)
    get setup_status_survey_path(s)
    assert_equal false, body["pending"], "a job killed before its ensure must not poll a tab forever"
  end

  test "the background comes back as the CSS custom property, not a bare URL" do
    s = survey
    s.update!(background_image: "/img/bg.jpg")
    get setup_status_survey_path(s)

    assert_includes body["background_css"], "--brand-bg-image:"
    assert_includes body["background_css"], "/img/bg.jpg"
    assert_includes body["background_css"], "linear-gradient",
                    "the gradient over the backdrop is part of the look and lives in " \
                    "one helper — rebuilding it in JS is how the two drift apart"
  end

  test "it is scoped to the caller's organisation" do
    other = Organisation.create!(name: "X", slug: "ss-x-#{SecureRandom.hex(3)}")
    theirs = other.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "k",
                                   default_locale: "en", locales: [ "en" ], cards: [])
    get setup_status_survey_path(theirs)
    assert_response :not_found, "another organisation's Verto must not be readable through this"
  end

  # ── The gap between polls ──────────────────────────────────────────────────
  # The editor polls every couple of seconds. An autosave landing between the
  # job's write and the next poll would still carry a deck with no imagery in
  # it, so the client's silence about imagery is not trusted while the flag
  # stands.

  test "an autosave during setup keeps the imagery it cannot see yet" do
    s = survey
    patch survey_path(s), params: {
      cards: [
        { "type" => "yes_no", "cid" => "c_1", "text" => "Edited by hand", "options" => %w[Yes No] },
        { "type" => "yes_no", "cid" => "c_2", "text" => "Q2", "options" => %w[Yes No] }
      ]
    }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success

    card = s.reload.cards.first
    assert_equal "Edited by hand", card["text"], "the creator's edit is the thing that must never be lost"
    assert_equal "/img/one.jpg", card["image"], "…and the imagery they cannot see yet must survive with it"
    assert_equal "a runner", card["subject"]
  end

  test "an autosave during setup still lets the creator clear an image deliberately" do
    s = survey
    # A deliberate removal comes with the card carrying its own media state —
    # here, a different picture. Fill-only means the stored one does not come
    # back on top of it.
    patch survey_path(s), params: {
      cards: [ { "type" => "yes_no", "cid" => "c_1", "text" => "Q1", "options" => %w[Yes No],
                 "image" => "/img/mine.jpg" } ]
    }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success

    assert_equal "/img/mine.jpg", s.reload.cards.first["image"],
                 "the creator's own pick outranks the populator's"
  end

  test "once setup is done an autosave clears imagery exactly as it always did" do
    s = survey(pending: false)
    patch survey_path(s), params: {
      cards: [ { "type" => "yes_no", "cid" => "c_1", "text" => "Q1", "options" => %w[Yes No] } ]
    }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success

    assert_nil s.reload.cards.first["image"],
               "outside the window the client is the authority on the deck — " \
               "removing an image has to keep working"
  end

  test "the merge follows cards through a reorder, because it matches on cid" do
    s = survey
    patch survey_path(s), params: {
      cards: [
        { "type" => "yes_no", "cid" => "c_2", "text" => "Q2", "options" => %w[Yes No] },
        { "type" => "yes_no", "cid" => "c_1", "text" => "Q1", "options" => %w[Yes No] }
      ]
    }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success

    cards = s.reload.cards
    assert_equal %w[c_2 c_1], cards.map { |c| c["cid"] }, "the creator's order stands"
    assert_nil   cards.first["image"], "c_2 never had a picture"
    assert_equal "/img/one.jpg", cards.second["image"],
                 "matching by INDEX here would have pasted c_1's picture onto c_2 — " \
                 "the wrong picture on the wrong card looks intentional, which is worse " \
                 "than no picture at all"
  end
end
