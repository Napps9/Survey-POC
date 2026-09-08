require "application_system_test_case"

# A font can be set on an Image List option that was added in this session.
#
# The floating rich-text toolbar appears only inside an element carrying
# data-rich-text. The server partial marks its option rows; the client template
# that "＋ Add option" (and every type-panel rebuild) used did not, so the new
# row could be typed into but never formatted — no toolbar, no font select —
# until the page was reloaded. Image Grid, which has no add button and is only
# ever server-rendered, worked, which is why the report named Image List ("you
# can't change the font of the list").
class OptionRichTextTest < ApplicationSystemTestCase
  CARD = "[data-card-type='multiple_choice']"

  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "ort-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Ort", email_address: "ort-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Fonts", theme: "Safety", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "multiple_choice", "cid" => "m1", "text" => "Which of these?",
                 "options" => [ "Automation", "Brand building" ] } ]
    )
  end

  # Select a label's whole text, the way a creator dragging over the word would.
  def select_contents(el)
    page.execute_script(<<~JS, el)
      const el = arguments[0]
      el.focus()
      const r = document.createRange(); r.selectNodeContents(el)
      const s = window.getSelection(); s.removeAllRanges(); s.addRange(r)
    JS
  end

  test "an option added in-session can be given a font, and the font is saved" do
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "Which of these?"

    list = find("#{CARD} .choice-list")
    list.find("li[data-card-editor-add]").click
    row = list.all(".pick-text[contenteditable]", minimum: 3).last

    # The add handler selects the new label itself, but the toolbar listens to
    # selectionchange on the next frame and a driver click can collapse the
    # selection — select deliberately, then expect the toolbar. This is the
    # assertion that failed before the fix: no [data-rich-text], no toolbar.
    select_contents(row)
    assert_selector ".rich-text-toolbar", visible: true, wait: 3

    page.execute_script(<<~JS)
      const s = document.querySelector('[data-rich-text-target="fontSelect"]')
      s.value = "font-poppins"
      s.dispatchEvent(new Event("change", { bubbles: true }))
    JS
    assert_selector "#{CARD} .pick-text span.font-poppins", wait: 3

    # The autosave is debounced; wait on the database, not on the status pill
    # (which already reads "Saved" before anything has happened).
    Timeout.timeout(10) do
      sleep 0.25 until Array(@survey.reload.cards.first["options_html"]).compact.any?
    end
    assert_match(/<span class="font-poppins">/, @survey.reload.cards.first["options_html"][2].to_s,
                 "the font chosen on the added option did not reach the stored deck")
  end
end
