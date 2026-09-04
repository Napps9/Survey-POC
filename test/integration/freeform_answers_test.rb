require "test_helper"

# Every answer to a freeform (open_ended) question, on the results page.
#
# The result card used to stop at twenty answers cut to 200 characters and a
# "+ N more" that led nowhere. Now the card previews the newest ten in full
# and offers "View all answers", whose panel pages through every one of them
# from SurveyTextAnswersController — newest first, within the segment and
# date range the page is showing, searchable. These cover the endpoint's
# contract and the two pages' halves of it; the panel itself is driven in
# test/system/freeform_answers_modal_test.rb.
class FreeformAnswersTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "open_ended",      "text" => "Why did you come?" },
    { "type" => "multiple_choice", "text" => "Colour?", "options" => %w[Blue Green] },
    { "type" => "open_ended",      "text" => "Where do you live?", "demographic" => "location" }
  ].freeze

  def setup
    @org   = Organisation.create!(name: "O", slug: "ff-#{SecureRandom.hex(3)}")
    @admin = make_user("admin")
    @org.memberships.create!(user: @admin, role: "admin")
    @survey = @org.surveys.create!(
      title: "FF", theme: "Th", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ], cards: CARDS,
      publish_token: SecureRandom.hex(8), published_at: Time.current
    )
    @link = @survey.survey_links.create!(name: "Newsletter", slug: "news-#{SecureRandom.hex(2)}")

    # 130 answers, one a minute, oldest first — so "newest first" is checkable
    # and the page size (100) is crossed. Every tenth one arrived through the
    # named link; the first three are blank, which is not an answer.
    130.times do |i|
      value = i < 3 ? "  " : "Answer #{i} — #{i.even? ? 'loved it' : 'fine'}"
      @survey.responses.create!(
        session_token: SecureRandom.uuid, status: "completed", locale: "en", answered: true,
        created_at: (200 - i).minutes.ago,
        survey_link: (i % 10).zero? ? @link : nil,
        answers: { "0" => { "type" => "open_ended", "value" => value },
                   "1" => { "type" => "multiple_choice", "value" => "Blue" } }
      )
    end
    # And one from long before the date-range presets reach.
    @survey.responses.create!(
      session_token: SecureRandom.uuid, status: "completed", locale: "en", answered: true,
      created_at: 40.days.ago,
      answers: { "0" => { "type" => "open_ended", "value" => "An old answer" } }
    )
  end

  def make_user(tag)
    User.create!(name: tag.capitalize, email_address: "#{tag}-#{SecureRandom.hex(3)}@test.com",
                 password: "verylongpassword")
  end

  def sign_in(user)
    delete session_path
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def answers(**params)
    get survey_results_answers_path(@survey, card_index: 0, **params), as: :json
    assert_response :success
    JSON.parse(response.body)
  end

  # ── The endpoint ─────────────────────────────────────────────────────────

  test "pages every answer newest first, blank ones left out" do
    sign_in @admin
    page1 = answers

    assert page1["ok"]
    assert_equal "Why did you come?", page1["question"]
    assert_equal 128, page1["total"], "127 non-blank recent answers plus the old one"
    assert_equal 128, page1["matched"]
    assert_equal 100, page1["answers"].size
    assert_equal 1, page1["page"]
    assert page1["has_more"]
    assert_equal "Answer 129 — fine", page1["answers"].first["text"]
    assert_match(/\A\d{4}-\d{2}-\d{2}T/, page1["answers"].first["at"])
    ats = page1["answers"].map { |a| a["at"] }
    assert_equal ats.sort.reverse, ats, "not newest first"

    page2 = answers(page: 2)
    assert_equal 28, page2["answers"].size
    refute page2["has_more"]
    assert_equal "An old answer", page2["answers"].last["text"]
    assert_empty page1["answers"].map { |a| a["text"] } & page2["answers"].map { |a| a["text"] }

    assert_empty answers(page: 9)["answers"]
  end

  test "search narrows to matching answers, case-insensitively, and says how many" do
    sign_in @admin
    data = answers(q: "LOVED")

    assert_equal 128, data["total"]
    assert_equal 63, data["matched"], "the even-numbered answers 4..128"
    assert_equal 63, data["answers"].size
    refute data["has_more"]
    assert data["answers"].all? { |a| a["text"].include?("loved it") }

    assert_equal 0, answers(q: "nothing like this")["matched"]
  end

  test "honours the page's segment and date range" do
    sign_in @admin

    via_link = answers(segment: "link_#{@link.id}")
    assert_equal 12, via_link["total"], "every tenth response came through the link, the blank first one aside"
    assert via_link["answers"].all? { |a| a["text"] =~ /Answer \d*0 /o }

    recent = answers(range: "7d")
    assert_equal 127, recent["total"], "the 40-day-old answer is outside the window"
    refute recent["answers"].any? { |a| a["text"] == "An old answer" }

    assert_equal 128, answers(segment: "no-such-segment")["total"], "an unknown segment falls back to Overall"
  end

  test "refuses a card that isn't a freeform question" do
    sign_in @admin

    get survey_results_answers_path(@survey, card_index: 1), as: :json
    assert_response :unprocessable_entity
    refute JSON.parse(response.body)["ok"]

    get survey_results_answers_path(@survey, card_index: 2), as: :json
    assert_response :unprocessable_entity, "the demographic tail is open_ended in shape only"

    get survey_results_answers_path(@survey, card_index: 40), as: :json
    assert_response :unprocessable_entity

    # -1 would be the last card, which is open_ended in shape — refused all the same.
    get survey_results_answers_path(@survey, card_index: -1), as: :json
    assert_response :unprocessable_entity
  end

  test "counts what the card counted: false is not an answer, 0 is" do
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", locale: "en", answered: true,
                              answers: { "0" => { "type" => "open_ended", "value" => false } })
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", locale: "en", answered: true,
                              answers: { "0" => { "type" => "open_ended", "value" => 0 } })
    sign_in @admin

    data = answers
    assert_equal 129, data["total"]
    assert_equal "0", data["answers"].first["text"]
    refute data["answers"].any? { |a| a["text"] == "false" }

    get survey_results_path(@survey)
    assert_select "button.freeform-view-all", text: /\(129\)/
  end

  test "is scoped to the signed-in organisation and needs a session" do
    other_org  = Organisation.create!(name: "Other", slug: "ff-other-#{SecureRandom.hex(3)}")
    other_user = make_user("other")
    other_org.memberships.create!(user: other_user, role: "admin")

    sign_in other_user
    get survey_results_answers_path(@survey, card_index: 0), as: :json
    assert_response :not_found

    delete session_path
    get survey_results_answers_path(@survey, card_index: 0)
    assert_redirected_to new_session_path
  end

  test "a viewer can read the answers — seeing results is what the role is for" do
    viewer = make_user("viewer")
    @org.memberships.create!(user: viewer, role: "viewer")
    sign_in viewer
    assert_equal 128, answers["total"]
  end

  # ── The pages ────────────────────────────────────────────────────────────

  test "the result card previews the newest ten in full and offers every answer" do
    sign_in @admin
    get survey_results_path(@survey, segment: "link_#{@link.id}", range: "30d")
    assert_response :success

    assert_select ".freeform-preview-item", 10
    assert_select ".freeform-preview-item", text: /Answer 120 — loved it/, count: 1
    refute_match "+ 3 more", response.body, "the dead '+ N more' line is gone"
    assert_select "button.freeform-view-all", count: 1 do |buttons|
      button = buttons.first
      assert_match "View all answers (12)", button.text
      url = button["data-freeform-answers-url-param"]
      assert_match %r{/surveys/#{@survey.id}/results/answers\?}, url
      assert_match "card_index=0", url
      assert_match "segment=link_#{@link.id}", url, "the panel must follow the page's segment"
      assert_match "range=30d", url, "the panel must follow the page's date range"
      assert_equal "Why did you come?", button["data-freeform-answers-question-param"]
    end
    assert_select "[data-freeform-answers-target='modal']", 1
  end

  test "a long answer is no longer cut to 200 characters in the preview" do
    long = "Long " * 80 # 400 characters
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", locale: "en", answered: true,
                              answers: { "0" => { "type" => "open_ended", "value" => long } })
    sign_in @admin
    get survey_results_path(@survey)
    assert_select ".freeform-preview-item__text", text: /\A\s*#{Regexp.escape(long.strip)}\s*\z/, count: 1
  end

  test "the public shared-results page keeps freeform answers hidden and has no panel" do
    @survey.update!(results_share_token: SecureRandom.urlsafe_base64(18), results_share_active: true)
    get shared_results_path(@survey.results_share_token)
    assert_response :success

    refute_match "freeform-view-all", response.body
    refute_match "Answer 129", response.body
    assert_select "[data-freeform-answers-target='modal']", 0
  end
end
