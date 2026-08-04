require "application_system_test_case"

# The per-card CTA rail has two states keyed off the right panel: expanded
# (icon + label) while the panel is closed, icons only once it opens. The
# labels are pure CSS (.is-panel-open hides .rail-label), so only a browser
# can assert the states actually swap.
class EditorCardRailTest < ApplicationSystemTestCase
  CARDS = [
    { "type" => "welcome_card", "title" => "Hello" },
    { "type" => "yes_no", "cid" => "c1", "text" => "A question?", "options" => %w[Yes No] }
  ].freeze

  def setup
    super
    @org  = Organisation.create!(name: "Rail", slug: "rl-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Rl", email_address: "rl-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(title: "Rail", theme: "Safety", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS)
  end

  def delete_label_display
    evaluate_script(
      "getComputedStyle(document.querySelector(\"[data-card-cid='c1'] .card-delete-btn .rail-label\")).display"
    )
  end

  test "rail labels show while the panel is closed and collapse to icons when it opens" do
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "A question?"

    # Panel closed on load: expanded rail, labels visible.
    assert_no_selector ".editor-grid.is-panel-open"
    refute_equal "none", delete_label_display,
                 "expanded rail must show the label next to the icon"

    # Selecting a card opens the right panel → icons only. Click the card's
    # number pill: it has no handler of its own, so the click bubbles to the
    # wrap's type-panel#selectCard (a click mid-card can land on the media
    # prompt, which opens the media modal instead).
    find("[data-card-cid='c1'] .card-num-pill").click
    assert_selector ".editor-grid.is-panel-open"
    assert_equal "none", delete_label_display,
                 "with the panel open the rail must collapse to icons"
    # The icon itself stays: the delete button still renders its svg.
    assert_selector "[data-card-cid='c1'] .card-delete-btn svg", visible: :all

    # Closing the panel brings the labels back.
    find(".right-tab-close").click
    assert_no_selector ".editor-grid.is-panel-open"
    refute_equal "none", delete_label_display
  end
end
