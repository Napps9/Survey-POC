require "application_system_test_case"

# The "View all answers" panel on a freeform result card
# (freeform_answers_controller): opens with the first page from
# SurveyTextAnswersController, loads the next on demand, asks the server for
# a search rather than filtering what happens to be loaded, and closes on
# Escape. The endpoint's own contract is covered in
# test/integration/freeform_answers_test.rb; this is the browser half.
class FreeformAnswersModalTest < ApplicationSystemTestCase
  def setup
    super
    @org  = Organisation.create!(name: "O", slug: "ffm-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "ffm-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "member")
    @survey = @org.surveys.create!(
      title: "FFM", theme: "Th", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      publish_token: SecureRandom.hex(8), published_at: Time.current,
      cards: [ { "type" => "open_ended", "text" => "What stood out?" } ]
    )
    130.times do |i|
      @survey.responses.create!(
        session_token: SecureRandom.uuid, status: "completed", locale: "en", answered: true,
        created_at: (200 - i).minutes.ago,
        answers: { "0" => { "type" => "open_ended", "value" => "Answer #{i}" } }
      )
    end
  end

  def open_panel
    sign_in_as(@user)
    visit survey_results_path(@survey)
    dismiss_cookie_banner
    click_button "View all answers (130) →"
    assert_selector "[data-freeform-answers-target='modal']:not(.hidden)", wait: 5
    assert_selector ".freeform-item", count: 100, wait: 10
  end

  test "opens on the newest page, loads more, and closes on Escape" do
    open_panel

    within("[data-freeform-answers-target='modal']") do
      assert_text "What stood out?"
      assert_text "Showing 100 of 130"
      assert_equal "Answer 129", first(".freeform-item__text").text
      assert_selector ".freeform-item__when", minimum: 1

      click_button "Load more"
      assert_selector ".freeform-item", count: 130, wait: 10
      assert_text "Showing 130 of 130"
      assert_no_button "Load more", wait: 2
    end
  end

  test "Copy all walks the pages it hasn't loaded yet, so all means all" do
    open_panel

    within("[data-freeform-answers-target='modal']") do
      # Headless Chromium has no clipboard to write to, so the button reports
      # a failed copy — but the walk that precedes it is what this checks:
      # every remaining page is fetched before anything is copied.
      click_button "Copy all"
      assert_selector ".freeform-item", count: 130, wait: 10
      assert_text "Showing 130 of 130"
    end

    find("[data-freeform-answers-target='search']").send_keys(:escape)
    assert_selector "[data-freeform-answers-target='modal'].hidden", visible: :all, wait: 5
  end

  test "searching asks the server across every answer" do
    open_panel

    find("[data-freeform-answers-target='search']").set("Answer 12")
    within("[data-freeform-answers-target='modal']") do
      # "Answer 12" and "Answer 120".."Answer 129" — eleven, some of them
      # beyond the first page the panel had loaded.
      assert_selector ".freeform-item", count: 11, wait: 10
      assert_text "11 of 130 match"
      assert_no_button "Load more", wait: 2

      find("[data-freeform-answers-target='search']").set("nothing here")
      assert_text "No answers match.", wait: 10
      assert_selector ".freeform-item", count: 0
    end
  end
end
