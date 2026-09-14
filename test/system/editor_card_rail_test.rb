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

  # The rail is a TWO-COLUMN grid, and a control whose label is a whole phrase
  # only gets a row to itself by being named in the `grid-column: 1 / -1` list
  # in application.css. Miss the list and the control takes half a rail — about
  # 62px, inside which any two-word label wraps and spills out of its pill.
  #
  # That is not hypothetical: the intro modal's control shipped missing from
  # that list and rendered exactly like that. Nothing caught it, because the
  # markup and the ERB comment both said "full-rail-width" and only the
  # stylesheet disagreed — so the assertion has to be on measured geometry.
  test "every phrase-labelled rail control gets the full rail, on one line" do
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "A question?"

    rail_width = evaluate_script(
      "document.querySelector(\"[data-card-cid='c1'] .rail-top\").getBoundingClientRect().width"
    )

    %w[card-delete-btn card-duplicate-btn card-modal-btn rail-add-btn].each do |klass|
      box = evaluate_script(<<~JS)
        (() => {
          const el = document.querySelector("[data-card-cid='c1'] .#{klass}");
          if (!el) return null;
          const r = el.getBoundingClientRect();
          const label = el.querySelector(".rail-label");
          const lh = label ? parseFloat(getComputedStyle(label).lineHeight) : 0;
          const lines = label ? Math.round(label.getBoundingClientRect().height / lh) : 1;
          return { width: r.width, height: r.height, lines };
        })()
      JS
      next if box.nil? # not every control renders on every card type

      assert_operator box["width"], :>, rail_width * 0.7,
                      ".#{klass} took half a rail — add it to the grid-column: 1 / -1 list"
      assert_equal 1, box["lines"],
                   ".#{klass}'s label wrapped, which means it does not fit its pill"
    end
  end

  # Collapsed, the rail is a three-column grid of 30px circles and the pop-up
  # control belongs in the Card N / Why row as its third circle. That takes
  # the control's membership of the collapsed `grid-column: auto` list in
  # application.css: without it the control keeps its expanded `1 / -1`,
  # forces a row of its own and stretches across it as an icon-only lozenge —
  # which is how it shipped (2026-09-14). Geometry again, because the markup
  # cannot tell: DOM order already put it third.
  #
  # Measured, not assumed, what this guards: deleting that list membership
  # fails the first assertion below; deleting the control's membership of the
  # circle-shaping list does NOT, because a 30px grid column already forces
  # the width and `border-radius: 100px` on a 30px box is a circle. That
  # second membership is kept for consistency with every sibling and against a
  # future column-width change, not because this test can see it.
  test "collapsed, the pop-up control is a circle beside Card N and Why" do
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "A question?"

    find("[data-card-cid='c1'] .card-num-pill").click
    assert_selector ".editor-grid.is-panel-open"

    rows = evaluate_script(<<~JS)
      (() => {
        const q = sel => document.querySelector("[data-card-cid='c1'] " + sel).getBoundingClientRect();
        const num = q(".card-num-pill"), why = q(".why-cta"), pop = q(".card-modal-btn");
        return { num: { top: num.top, w: num.width, h: num.height },
                 why: { top: why.top, w: why.width, h: why.height },
                 pop: { top: pop.top, w: pop.width, h: pop.height, left: pop.left, whyRight: why.right } };
      })()
    JS

    assert_in_delta rows["num"]["top"], rows["pop"]["top"], 1,
                    "the pop-up control must share Card N's row when collapsed"
    assert_in_delta rows["why"]["top"], rows["pop"]["top"], 1,
                    "…and Why's — three circles on one line"
    assert_operator rows["pop"]["left"], :>=, rows["pop"]["whyRight"],
                    "it sits AFTER Why, as the row's third circle"
    assert_in_delta 30, rows["pop"]["w"], 1, "collapsed it is the 30px circle every other control is"
    assert_in_delta 30, rows["pop"]["h"], 1
    assert_in_delta rows["why"]["w"], rows["pop"]["w"], 1, "the same size as its neighbours"
  end
end
