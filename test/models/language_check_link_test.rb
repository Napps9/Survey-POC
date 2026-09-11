require "test_helper"

# The shareable review link. Its job is to be a narrow capability: one Verto's
# wording, in named languages, optionally read-only, switch-offable.
class LanguageCheckLinkTest < ActiveSupport::TestCase
  def setup
    @org = Organisation.create!(name: "LCL", slug: "lcl-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "k",
                                   default_locale: "en", locales: %w[en es fr],
                                   cards: [ { "cid" => "c1", "type" => "open_ended", "text" => "Why?" } ])
  end

  test "a link mints its own unguessable token" do
    link = @survey.language_check_links.create!
    assert link.token.present?
    assert link.token.length >= 20
    assert_not_equal link.token, @survey.language_check_links.create!.token
  end

  test "an empty scope means every language the Verto has" do
    assert_equal %w[en es fr], @survey.language_check_links.create!.visible_locales
  end

  test "a scope is intersected with the Verto's current languages" do
    link = @survey.language_check_links.create!(locales: %w[es de])
    assert_equal [ "es" ], link.visible_locales,
                 "a language the Verto does not have is not a language to review"
  end

  test "a link stops offering a language the Verto has dropped" do
    link = @survey.language_check_links.create!(locales: %w[es fr])
    @survey.update!(locales: %w[en fr])
    assert_equal [ "fr" ], link.visible_locales
  end

  test "editable? is both switches, not just the edit one" do
    link = @survey.language_check_links.create!(can_edit: true)
    assert link.editable?
    link.update!(active: false)
    assert_not link.editable?, "a paused link cannot write, whatever its edit flag says"
  end

  test "last_seen_at is not rewritten on every request of a review session" do
    link = @survey.language_check_links.create!
    link.touch_seen!
    first = link.last_seen_at
    assert first.present?
    link.touch_seen!
    assert_equal first, link.reload.last_seen_at,
                 "a reviewer ticking thirty lines must not cost thirty writes"
  end

  test "an unnamed link still has something to call itself" do
    assert_equal I18n.t("language_check.link_default_name"),
                 @survey.language_check_links.create!.display_name
  end
end
