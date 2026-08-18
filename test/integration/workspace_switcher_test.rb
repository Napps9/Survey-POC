require "test_helper"

# Workspaces: the account you are acting in, shown beside the logo and
# switchable from there or from the ⌘K palette. The membership model already
# supported several accounts per user — what was missing was any affordance
# saying so.
class WorkspaceSwitcherTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "Multi", email_address: "ws-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @first  = Organisation.create!(name: "Acme Research", slug: "acme-#{SecureRandom.hex(3)}")
    @second = Organisation.create!(name: "Beta Foundation", slug: "beta-#{SecureRandom.hex(3)}")
    @first.memberships.create!(user: @user, role: "admin")
    @second.memberships.create!(user: @user, role: "member")

    @solo = User.create!(name: "Solo", email_address: "solo-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @solo_org = Organisation.create!(name: "Only Org", slug: "only-#{SecureRandom.hex(3)}")
    @solo_org.memberships.create!(user: @solo, role: "admin")
  end

  def sign_in(user)
    delete session_path
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  test "a single-workspace user sees the workspace as context, with nothing to open" do
    sign_in @solo
    get root_path
    assert_response :success

    assert_match "Only Org", response.body
    assert_match 'data-static="true"', response.body
    refute_match "command-palette#toggleWorkspace", response.body,
                 "a one-row menu is noise — the chip should be static"
  end

  test "a multi-workspace user gets a switcher listing every workspace with its role" do
    sign_in @user
    get root_path
    assert_response :success

    assert_match "command-palette#toggleWorkspace", response.body
    assert_match 'data-command-palette-target="workspacePopover"', response.body
    assert_match "Acme Research", response.body
    assert_match "Beta Foundation", response.body
    # The current workspace is marked, not offered as a destination.
    assert_match 'data-current="true"', response.body
    # Roles come from the preloaded membership hash.
    assert_match I18n.t("nav.role_admin"), response.body
    assert_match I18n.t("nav.role_member"), response.body
  end

  test "switching moves the acting account and shows that account's Vertos" do
    @first.surveys.create!(title: "Acme Verto", theme: "T", audience_age: "a", key_insight: "k",
                           default_locale: "en", locales: [ "en" ])
    @second.surveys.create!(title: "Beta Verto", theme: "T", audience_age: "a", key_insight: "k",
                            default_locale: "en", locales: [ "en" ])
    sign_in @user

    post switch_organisation_path, params: { organisation_id: @second.id }
    assert_redirected_to root_url
    follow_redirect!

    assert_match "Beta Verto", response.body
    refute_match "Acme Verto", response.body, "still showing the workspace we switched away from"
  end

  # Deliberate: every deep page is scoped to Current.organisation.surveys, so
  # returning to one after the org changes would 404.
  test "switching lands on the target workspace's home, not the page you came from" do
    funder_org = Organisation.create!(name: "Funder Co", slug: "fund-#{SecureRandom.hex(3)}",
                                      funder_enabled: true)
    funder_org.memberships.create!(user: @user, role: "admin")
    sign_in @user

    post switch_organisation_path, params: { organisation_id: funder_org.id }
    assert_redirected_to funders_url,
                         "a funder-owner workspace should land on its own dashboard"
  end

  test "switching to a workspace you do not belong to is a silent no-op" do
    outsider = Organisation.create!(name: "Not Yours", slug: "not-#{SecureRandom.hex(3)}")
    sign_in @user
    get root_path

    post switch_organisation_path, params: { organisation_id: outsider.id }
    follow_redirect!

    assert_match "Acme Research", response.body, "the acting workspace should not have changed"
    refute_match "Not Yours", response.body
  end

  test "the command palette lists the other workspaces as searchable entries" do
    sign_in @user
    get root_path
    assert_response :success

    assert_match 'data-section="workspaces"', response.body
    # The target and search text must sit on the BUTTON: filter() reads
    # dataset.searchText and Enter calls .click(), and clicking a form is inert.
    assert_match(/<button[^>]*data-command-palette-target="item"[^>]*data-search-text="beta foundation[^"]*"/,
                 response.body)
  end

  test "the user menu no longer carries a second copy of the switcher" do
    sign_in @user
    get root_path

    # Exactly one switch form per other workspace — the old flat list in the
    # user popover plus the new switcher would give two.
    forms = response.body.scan(%r{action="#{switch_organisation_path}"}).size
    assert_equal 2, forms,
                 "expected one switch form in the workspace popover and one in the palette, got #{forms}"
  end
end
