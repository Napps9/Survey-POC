require "test_helper"

# CardTypes.badge/panel_label (2.7) follow the CREATOR's own platform
# language (I18n.locale, threaded through by ApplicationController#switch_locale),
# not any Verto's content locale — dashboard chrome, never respondent-facing.
# This is the one check that proves the whole chain end to end through a real
# request: ?locale=fr -> resolve_locale -> switch_locale -> I18n.locale ->
# CardTypes.badge's default -> the rendered page. Everything below it
# (parity test, card_types_test's direct-call unit tests) checks a piece in
# isolation; this is what would have caught the eyebrow precedent's own class
# of bug (the i18n key existing but never actually being read at the call site).
class CardTypeLocaleTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "ctl-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org = Organisation.create!(name: "O", slug: "ctl-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    @survey = @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                                   default_locale: "en", locales: [ "en" ],
                                   cards: [ { "type" => "welcome_card", "title" => "hi" } ])
    # Stage a recently-deleted card directly (bypassing the whole delete flow)
    # so surveys/show renders the one view that reads CardTypes.badge — see
    # show.html.erb's "Recently deleted" block.
    @survey.update_column(:deleted_cards, [
      { "card" => { "type" => "range", "cid" => "gone1", "title" => "An old range card" } }
    ])
  end

  test "the editor shows the English badge by default" do
    get survey_path(@survey)
    assert_response :success
    assert_select ".deleted-card-type", text: "RANGE"
  end

  test "?locale=fr renders the French badge instead, from the SAME YAML-fallback code path" do
    get survey_path(@survey), params: { locale: "fr" }
    assert_response :success
    assert_select ".deleted-card-type", text: "ÉCHELLE"
    refute_match "\">RANGE<", response.body
  end
end
