require "test_helper"

# P2-9c. /play/:token is a capability URL — the token is the whole of the
# authorisation — so an indexed one publishes the capability, not just a page.
# Same for the invite and funder-invite token routes, and /blazer is staff-only.
#
# Nothing pinned any of this: a grep of test/ for "robots" returned nothing, and
# public/robots.txt had never been deliberately edited, so a Rails upgrade
# regenerating the default file would have silently undone it.
class SearchIndexingTest < ActionDispatch::IntegrationTest
  ROBOTS = Rails.root.join("public/robots.txt")

  def setup
    @user = User.create!(name: "U", email_address: "idx-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "idx-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Live", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "Hi" },
               { "type" => "yes_no", "text" => "Ok?", "options" => %w[Yes No] } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
  end

  test "robots.txt disallows every capability path" do
    body = ROBOTS.read
    assert_match(/^User-agent: \*/, body)
    %w[/play/ /invites/ /funder_invites/ /blazer].each do |path|
      assert_match(/^Disallow: #{Regexp.escape(path)}\s*$/, body,
                   "robots.txt should disallow #{path}")
    end
  end

  test "robots.txt is served" do
    # It lives in public/ and is served by the file server
    # (RAILS_SERVE_STATIC_FILES=1 in render.yaml), so no route is involved —
    # but if that ever changes this catches it.
    get "/robots.txt"
    assert_response :success
    assert_match(/Disallow: \/play\//, response.body)
  end

  # The half that binds. robots.txt is advisory and only reaches a crawler that
  # fetches it; the header travels with the response itself, which is what
  # matters when a link is followed from somewhere else entirely.
  test "the player sends noindex" do
    get play_survey_path(@survey.publish_token)
    assert_response :success
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
  end

  test "the invite acceptance page sends noindex" do
    invite = Invite.create!(organisation: @org, email_address: "someone@test.com",
                            role: "member", invited_by: @user, expires_at: 7.days.from_now)
    get invite_path(invite.token)
    assert_includes [ 200, 302, 404 ], response.status
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
  end

  # The negative case. Without it the header could be set unconditionally and
  # every test above would still pass, while the marketing pages quietly
  # de-indexed themselves.
  test "ordinary signed-in pages are still indexable-by-default" do
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    get root_path
    assert_response :success
    assert_nil response.headers["X-Robots-Tag"],
               "only capability URLs should carry noindex — a blanket header would " \
               "de-index the public marketing pages too"
  end

  test "the sign-in page is not de-indexed" do
    get new_session_path
    assert_response :success
    assert_nil response.headers["X-Robots-Tag"]
  end

  # A path that merely STARTS with a disallowed word must not be caught — and
  # conversely /play itself must be.
  test "the noindex matcher is anchored to whole path segments" do
    matcher = ApplicationController::NOINDEX_PATHS
    assert matcher.match?("/play/abc123")
    assert matcher.match?("/play")
    assert matcher.match?("/blazer/queries/1")
    refute matcher.match?("/playbooks")
    refute matcher.match?("/surveys/1")
    refute matcher.match?("/organisations")
  end
end
