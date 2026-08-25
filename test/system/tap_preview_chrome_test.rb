require "application_system_test_case"

# The editor's Preview overlay is not rendered by `_card_component` at all —
# preview_verto_controller DEEP-CLONES the editor's live card DOM and strips the
# editor-only chrome by selector. So every affordance added to the editor's card
# markup reaches Preview by default, and stays there until someone remembers to
# put it on that list.
#
# The statement pager was not on it, and it is the one piece of editor chrome
# that a flat remove would not have fixed either: it does not sit BESIDE a
# respondent control, it takes one's place. `_card_component` renders the pager
# in :editor mode INSTEAD of the reset row, so a previewed tap card showed the
# creator's ‹ Statement 1 of 5 › and had no Reset at all — it gained a control a
# respondent should never see and lost one they should.
#
# Preview is what a creator checks the Verto against before publishing, so a
# wrong Preview is worse than a cosmetic slip: it is the wrong answer to
# "is this ready?". Hence a browser test — nothing below one runs the clone.
#
# The published player and Test Mode are server-rendered and were never
# affected; test/integration/tap_pager_is_editor_only_test.rb holds that half.
class TapPreviewChromeTest < ApplicationSystemTestCase
  STATEMENTS = [ "Meetings drain me", "I get deep work done", "Fridays are wasted" ].freeze

  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "tpc-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Tpc", email_address: "tpc-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(
      title: "Tap", theme: "Safety", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Hello" },
        { "type" => "tap_card", "cid" => "t1", "text" => "React to these",
          "options" => STATEMENTS.dup }
      ]
    )
  end

  def open_preview
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_selector "[data-card-cid='t1'] .tap-nav-row"

    # Not [data-action*='publish-panel#open'] — that substring also matches the
    # Design button's `publish-panel#openDesign`, which opens the branding panel
    # instead and leaves no Preview button to find.
    find("button[data-action='click->publish-panel#open click->editor-panel#open']").click
    click_button "▶ Preview Verto"

    # The overlay opens on card 1, the welcome card — every other preview card
    # is built but hidden, so the tap card has to be walked to before anything
    # on it can be seen rather than merely found in the DOM.
    assert_selector ".preview-overlay .preview-card.active", wait: 5
    find("[data-preview-verto-target='nextBtn']").click
    assert_selector ".preview-overlay .preview-card.active .rotate-card-stack", wait: 5
  end

  test "the preview shows a respondent's tap card, not the creator's" do
    open_preview

    assert page.has_no_css?(".preview-overlay .tap-nav-row", visible: :all),
           "the creator's statement pager is in Preview — Preview is what a Verto gets checked " \
           "against before it ships, so this is the wrong answer to 'is this ready?'"
    assert page.has_no_css?(".preview-overlay .tap-nav-btn", visible: :all),
           "the pager's chevrons survived the strip"
    assert page.has_css?(".preview-overlay .preview-card.active .rotate-reset-btn"),
           "removing the pager took Reset with it — in the editor the pager stands IN ITS " \
           "PLACE, so the clone has to swap the two, not just strip one"
  end

  # The swapped-in row has to be the working control, not a picture of one.
  test "the preview's Reset is wired to the stack it belongs to" do
    open_preview

    first = evaluate_script(<<~JS)
      document.querySelector(".preview-overlay .preview-card.active .rotate-card .rotate-card-statement span").textContent.trim()
    JS
    find(".preview-overlay .preview-card.active [data-response-key='no']", match: :first).click
    assert_selector ".preview-overlay .preview-card.active .rotate-dot.done", wait: 3

    find(".preview-overlay .preview-card.active .rotate-reset-btn").click
    assert_no_selector ".preview-overlay .preview-card.active .rotate-dot.done", wait: 3
    assert_equal first, evaluate_script(<<~JS), "Reset did not put the deck back to its first statement"
      document.querySelector(".preview-overlay .preview-card.active .rotate-card[style*='pointer-events: auto'] .rotate-card-statement span")?.textContent?.trim()
        || document.querySelector(".preview-overlay .preview-card.active .rotate-card .rotate-card-statement span").textContent.trim()
    JS
  end

  # The rest of the strip list is what stopped the previous leaks; a pager fix
  # that quietly dropped one of those would trade this bug for an older one.
  test "the previewed card keeps its existing editor chrome stripped" do
    open_preview

    [ ".tap-card-delete", ".tap-add-btn", ".tap-card-image-btn", "[contenteditable]" ].each do |sel|
      assert page.has_no_css?(".preview-overlay #{sel}", visible: :all),
             "#{sel} reached the preview clone"
    end
  end

  # Found while pinning the pager down, and older than it: `option-style` is
  # bound on the EDITOR ROOT, an ancestor of this overlay, so a cloned 🎨 — or
  # the answer mark, which is the popover's real click target on a tap card —
  # opened the creator's colour picker from inside a respondent view. The mark
  # case also swallowed the answer, because option-style#open stops
  # propagation, so a previewed deck could not be answered at all.
  test "no per-answer style or remove control survives into the preview" do
    open_preview

    [ ".option-style-btn", ".tap-response-delete" ].each do |sel|
      assert page.has_no_css?(".preview-overlay #{sel}", visible: :all),
             "#{sel} reached the preview clone — `option-style` is bound on the editor root, so " \
             "this one is live, not inert"
    end
    assert page.has_no_css?('.preview-overlay [data-action*="option-style#"]', visible: :all),
           "an answer in Preview still opens the style popover on click"
    assert page.has_no_css?(".preview-overlay .rotate-action-btn--editable", visible: :all),
           "the mark still advertises itself as the creator's style control"
  end
end
