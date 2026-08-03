require "test_helper"

# window.I18N is the only channel JS strings reach the browser through. It has
# always carried the `js:` namespace; the editor's client-side card builders
# (type_panel_controller COMPONENTS) additionally need the shared strings the
# server renders from `card:`/`editor:`/`player:` — curated into the payload
# by layouts/_i18n_js. If that slice regresses, every builder string silently
# falls back to its raw dotted key in the UI, which no Ruby-side locale test
# can see. This pins the contract at the rendered-page level.
class I18nJsExportTest < ActionDispatch::IntegrationTest
  def i18n_payload
    get new_session_path
    assert_response :success
    script = response.body[/window\.I18N = (\{.*?\});/m, 1]
    assert script, "the layout no longer renders window.I18N"
    JSON.parse(script)
  end

  test "window.I18N carries the js namespace plus the curated shared slice" do
    data = i18n_payload

    # js: namespace (the original contract)
    assert data.dig("player", "progress").present?, "js.player missing"
    assert data.dig("editor", "scenario", "page_of").present?, "js.editor.scenario missing"

    # curated card slice — the builders' chrome
    assert_equal I18n.t("card.add_option"), data.dig("card", "add_option")
    assert_equal I18n.t("card.characters"), data.dig("card", "characters")

    # curated editor/player keys the consent-gate builder mirrors from the ERB
    assert_equal I18n.t("editor.consent_agreement_kicker"), data.dig("editor", "consent_agreement_kicker")
    assert_equal I18n.t("player.consent_agree"), data.dig("player", "consent_agree")
    assert_equal I18n.t("player.visit_website"), data.dig("player", "visit_website")
  end

  test "a non-English locale resolves the slice in that language" do
    get new_session_path, params: { locale: "fr" }
    assert_response :success
    script = response.body[/window\.I18N = (\{.*?\});/m, 1]
    data = JSON.parse(script)

    assert_equal I18n.t("card.add_option", locale: :fr), data.dig("card", "add_option"),
                 "the slice must resolve per-locale, not pin English"
    refute_equal I18n.t("card.add_option", locale: :en), data.dig("card", "add_option"),
                 "fr should differ from en for this key — if it doesn't, the locale " \
                 "either lost the key or the payload ignored the locale"
  end
end
