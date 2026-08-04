require "test_helper"

# Grid answer types render two columns, never three — three shrank the tiles
# and labels too far to read. The old rule switched to .choice-grid-3 at five
# options, so this pins the once-switching case (6 options) to two columns in
# both the player and the editor. The JS side (type_panel's gridHtml rebuild)
# is pinned alongside, since a re-applied type would otherwise resurrect the
# three-column layout on the next autosave.
class ChoiceGridColumnsTest < ActionDispatch::IntegrationTest
  def setup
    @org  = Organisation.create!(name: "Grid", slug: "grid-#{SecureRandom.hex(2)}")
    @user = User.create!(name: "U", email_address: "gr-#{SecureRandom.hex(2)}@test.com",
                         password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "S", theme: "Sports", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "select_many_grid", "text" => "Pick some",
                 "options" => %w[One Two Three Four Five Six] } ]
    )
    @survey.update!(publish_token: SecureRandom.hex(8))
  end

  test "the player renders a six-option grid in two columns" do
    get play_survey_path(@survey.publish_token)

    assert_response :success
    assert_select "ul.choice-grid.choice-grid-2", 1
    assert_select ".choice-grid-3", 0
  end

  test "the editor renders the same grid in two columns" do
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    @survey.update!(publish_token: nil)

    get survey_path(@survey)

    assert_response :success
    assert_select "ul.choice-grid.choice-grid-2", 1
    assert_select ".choice-grid-3", 0
  end

  test "the type panel's JS rebuild never emits a three-column grid" do
    source = File.read(Rails.root.join("app/javascript/controllers/type_panel_controller.js"))
    assert_includes source, "choice-grid-2",
                    "gridHtml no longer hardcodes the two-column class"
    refute_match(/choice-grid-3|choice-grid-\$\{/, source,
                 "gridHtml computes a column count again — a re-applied grid type " \
                 "would come back three-wide")
  end
end
