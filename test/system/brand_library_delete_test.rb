require "application_system_test_case"

# Removing a brand asset from the picker's own grid.
#
# Both halves of this already existed and never met: Settings → Brand had a
# working ×, and DELETE /organisations/:id/assets/:id has been live since the
# library shipped — but the grid a creator is looking at when they decide an
# image was a mistake is the PICKER's, and that one had no affordance at all.
#
# The interesting part is not the delete; it is that the delete happens inside
# a modal floating over an editor that may be holding unsaved cards. The
# endpoint's HTML branch redirects, and a redirect followed by Turbo would take
# those cards with it — so the picker asks for JSON and this suite pins that
# the editor is still standing afterwards.
class BrandLibraryDeleteTest < ApplicationSystemTestCase
  def setup
    super
    @user = User.create!(name: "U", email_address: "lib-del-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "lib-del-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @org.assets.attach(io: StringIO.new(SVG_BYTES), filename: "brand.svg", content_type: "image/svg+xml")
    @survey = @org.surveys.create!(
      title: "Lib", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "hi" },
        { "type" => "multiple_choice", "cid" => "q1", "text" => "Pick", "options" => %w[A B] }
      ]
    )
  end

  # SVG deliberately, not PNG: as_thumb_path only reaches for a variant when
  # blob.variable?, and SVG isn't — so the tile's background-image is the blob
  # itself and the suite doesn't need libvips on the box to render a thumbnail
  # it never looks at.
  SVG_BYTES = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 4 4">) +
              %(<rect width="4" height="4" fill="#01EACB"/></svg>)

  def open_picker
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "Pick"
    find(".survey-card-wrap[data-card-cid='q1'] .split-left-design-prompt", match: :first).click
    assert_selector ".media-modal-backdrop", visible: true
  end

  test "an admin removes a brand asset from the picker and stays in the editor" do
    open_picker
    assert_selector ".media-library-cell .media-library-item", count: 1

    accept_confirm { find(".media-library-cell .media-library-del").click }

    assert_no_selector ".media-library-cell .media-library-item"
    assert_equal 0, @org.reload.assets.attachments.size

    # The whole reason destroy grew a JSON branch: a redirect here would have
    # navigated the editor away to make a thumbnail disappear.
    assert_selector ".media-modal-backdrop", visible: true
    assert_current_path survey_path(@survey), ignore_query: true
  end

  test "declining the confirm leaves the asset alone" do
    open_picker
    dismiss_confirm { find(".media-library-cell .media-library-del").click }

    assert_selector ".media-library-cell .media-library-item", count: 1
    assert_equal 1, @org.reload.assets.attachments.size
  end

  # Apply is armed by a pending URL, not by what is on screen. Delete the tile
  # that armed it and Apply stayed lit, pointing at a blob that had just been
  # purged — one click from putting a 404 on the card.
  test "removing the tile that armed Apply disarms it" do
    open_picker
    find(".media-library-cell .media-library-item").click
    assert_equal false, apply_disabled?, "picking a tile should arm Apply"

    accept_confirm { find(".media-library-cell .media-library-del").click }

    assert_equal true, apply_disabled?,
                 "Apply is still armed for an image that no longer exists — applying it " \
                 "would put a purged blob URL on the card"
  end

  def apply_disabled?
    page.evaluate_script(
      "!!document.querySelector('[data-media-picker-target=applyBtn]').disabled"
    )
  end

  test "a member sees the brand library but is offered no way to delete from it" do
    member = User.create!(name: "M", email_address: "lib-mem-#{SecureRandom.hex(3)}@test.com",
                          password: "verylongpassword")
    @org.memberships.create!(user: member, role: "member")

    sign_in_as(member)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "Pick"
    find(".survey-card-wrap[data-card-cid='q1'] .split-left-design-prompt", match: :first).click
    assert_selector ".media-modal-backdrop", visible: true

    assert_selector ".media-library-cell .media-library-item", count: 1
    assert_no_selector ".media-library-del"
  end
end
