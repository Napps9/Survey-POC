require "test_helper"

# The fullscreen layout locked the viewport (`overflow:hidden` on <body>) for
# every page it served. That's right for the player, which is a full-bleed
# experience, but on the unauthenticated auth pages it trapped the visitor:
# `overflow:hidden` doesn't stop the *browser* scrolling a focused field into
# view, only the user scrolling afterwards. So clicking into a text box on the
# sign-up form — which is taller than a laptop viewport, and taller still with
# a phone keyboard up — shifted the page and then froze it there, putting the
# fields above and the legal footer below permanently out of reach.
class AuthPageScrollingTest < ActionDispatch::IntegrationTest
  def body_tag
    response.body[/<body[^>]*>/]
  end

  def published_survey
    org = Organisation.create!(name: "Scroll Co", slug: "scroll-#{SecureRandom.hex(3)}")
    org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "hi" } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
  end

  test "the unauthenticated auth pages scroll" do
    { "sign up" => new_registration_path,
      "sign in" => new_session_path,
      "password reset" => new_password_path }.each do |name, path|
      get path
      assert_response :success
      assert_no_match(/overflow:\s*hidden/, body_tag,
                      "the #{name} page can be taller than the viewport, so it must scroll")
      assert_match(/min-height:100dvh/, body_tag, "the #{name} page should still fill the viewport")
    end
  end

  test "the sign-up page keeps its submit button and legal footer in the document" do
    get new_registration_path
    assert_response :success

    # Both sit below the fold on a short viewport — unreachable while the body
    # was locked, which is the bug this guards.
    assert_select "input[type=submit]"
    assert_select "footer.legal-footer"
  end

  test "the player still locks the viewport" do
    get play_survey_path(published_survey.publish_token)
    assert_response :success
    assert_match(/overflow:hidden/, body_tag,
                 "the player is a full-bleed experience and must not scroll")
  end

  test "the signed-in shell still locks the viewport and scrolls in its own container" do
    user = User.create!(name: "U", email_address: "scroll-#{SecureRandom.hex(2)}@test.com",
                        password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "scroll-org-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    assert_response :success
    assert_match(/overflow:hidden/, body_tag)
    # The signed-in shell does its own scrolling inside a fixed container, so
    # the locked body is deliberate here.
    assert_match(/position:\s*fixed;[^"]*overflow:\s*auto/, response.body)
  end
end
