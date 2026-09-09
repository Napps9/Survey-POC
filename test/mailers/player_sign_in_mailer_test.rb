require "test_helper"

# The link a respondent asked for at the end of a Verto.
class PlayerSignInMailerTest < ActionMailer::TestCase
  def player(locale: nil)
    Player.create!(email_address: "psm-#{SecureRandom.hex(4)}@test.com", preferred_locale: locale)
  end

  def survey(org_name: "Haverley Town Council")
    org = Organisation.create!(name: org_name, slug: "psm-#{SecureRandom.hex(3)}")
    org.surveys.create!(title: "T", theme: "Car-free High Street", audience_age: "all",
      key_insight: "x", default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
  end

  test "it is addressed to the player and carries the link" do
    pl = player
    _link, raw = PlayerSignInLink.mint!(player: pl)
    mail = PlayerSignInMailer.sign_in(pl, raw, survey)

    assert_equal [ pl.email_address ], mail.to
    assert_match(/#{Regexp.escape(raw)}/, mail.html_part.body.to_s, "the link is the whole email")
  end

  # The respondent has a relationship with the organisation that asked them
  # something, not with us. We are the "via".
  test "the subject names the organisation" do
    mail = PlayerSignInMailer.sign_in(player, "tok", survey(org_name: "Riverside Youth Trust"))
    assert_match(/Riverside Youth Trust/, mail.subject)
  end

  test "it falls back to a plain subject with no survey" do
    mail = PlayerSignInMailer.sign_in(player, "tok", nil)
    assert_equal I18n.t("player_sign_in_mailer.subject"), mail.subject
  end

  test "both parts carry the link, the expiry and the ignore-it line" do
    pl = player
    _link, raw = PlayerSignInLink.mint!(player: pl)
    mail = PlayerSignInMailer.sign_in(pl, raw, survey)

    [ mail.html_part, mail.text_part ].each do |part|
      body = part.body.to_s
      assert_match(/#{Regexp.escape(raw)}/, body, "#{part.content_type} must carry the link")
      assert_match(/20 minutes/, body, "#{part.content_type} must say how long it lasts")
      assert_match(/ignore this email/i, body,
        "#{part.content_type}: someone who didn't ask has to be told nothing happened")
    end
  end

  # A mailer runs in a Solid Queue job with no request, so Current.locale is
  # never set — without I18n.with_locale this renders in whatever locale the
  # worker was last left in.
  test "it renders in the recipient's preferred locale" do
    mail = PlayerSignInMailer.sign_in(player(locale: "fr"), "tok", nil)
    assert_equal I18n.t("player_sign_in_mailer.subject", locale: :fr), mail.subject
  end

  test "an unsupported or missing preferred_locale falls back to English" do
    [ nil, "", "klingon" ].each do |locale|
      mail = PlayerSignInMailer.sign_in(player(locale: locale), "tok", nil)
      assert_equal I18n.t("player_sign_in_mailer.subject", locale: :en), mail.subject,
        "#{locale.inspect} should coerce to the default locale"
    end
  end

  test "it restores the surrounding locale" do
    before = I18n.locale
    PlayerSignInMailer.sign_in(player(locale: "de"), "tok", nil).subject
    assert_equal before, I18n.locale,
      "the job process is shared — the next mail out would inherit it"
  end
end
