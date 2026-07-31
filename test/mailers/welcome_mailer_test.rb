require "test_helper"

# P2-6a. The getting-started email, and — more importantly — *when* it is sent.
class WelcomeMailerTest < ActionMailer::TestCase
  def user(locale: nil)
    User.create!(name: "W", email_address: "w-#{SecureRandom.hex(4)}@test.com",
                 password: "verylongpassword", preferred_locale: locale)
  end

  test "it is addressed to the user and names the product" do
    u = user
    mail = WelcomeMailer.welcome(u)
    assert_equal [ u.email_address ], mail.to
    assert_match(/Playverto/, mail.subject)
  end

  test "both parts carry the getting-started steps" do
    mail = WelcomeMailer.welcome(user)
    [ mail.html_part, mail.text_part ].each do |part|
      body = part.body.to_s
      assert_match(/template/i, body, "#{part.content_type} should point at the template gallery")
      assert_match(/Verto score/i, body)
      assert_match(/QR/, body)
    end
  end

  test "the call to action links to the template gallery" do
    body = WelcomeMailer.welcome(user).html_part.body.to_s
    assert_match(/href="[^"]*\/templates"/, body)
  end

  # A mailer runs in a Solid Queue job with no request, so Current.locale is
  # never set — without I18n.with_locale the mail renders in whatever locale the
  # worker was last left in, which is a coin flip.
  test "it renders in the recipient's preferred locale" do
    mail = WelcomeMailer.welcome(user(locale: "fr"))
    assert_equal I18n.t("welcome_mailer.subject", locale: :fr), mail.subject
    assert_match(/modèle/i, mail.html_part.body.to_s)
  end

  test "an unsupported or missing preferred_locale falls back to English" do
    [ nil, "", "klingon" ].each do |locale|
      mail = WelcomeMailer.welcome(user(locale: locale))
      assert_equal I18n.t("welcome_mailer.subject", locale: :en), mail.subject,
                   "#{locale.inspect} should coerce to the default locale"
    end
  end

  # Rendering in another locale must not leave the process in it — the job
  # process is shared, and the next mail out would inherit it.
  test "it restores the surrounding locale" do
    before = I18n.locale
    WelcomeMailer.welcome(user(locale: "de")).subject
    assert_equal before, I18n.locale
  end
end
