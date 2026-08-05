require "test_helper"

# Answer icon tiles derived from the Verto's brand colour, chosen in the create
# flow (and the Design panel) beside the colours themselves.
class BrandAnswerTintTest < ActionDispatch::IntegrationTest
  def setup
    @org  = Organisation.create!(name: "Tint", slug: "tnt-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "T", email_address: "tnt-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Tint", theme: "Sports", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      brand_palette: { "primary" => "#8B5CF6", "cta" => "#01EACB", "bg" => "#1C2034" },
      cards: [ { "type" => "multiple_choice", "cid" => "c1", "text" => "Q", "options" => %w[a b] } ]
    )
  end

  def sign_in
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
  end

  test "the ramp is one family of six, lightest first" do
    grads = BrandPalette.tile_gradients("#8B5CF6")

    assert_equal 6, grads.size
    assert_equal grads.uniq.size, grads.size, "each tile must be distinguishable"
    grads.each { |g| assert_match(/\Alinear-gradient\(135deg, #[0-9A-F]{6}, #[0-9A-F]{6}\)\z/, g) }

    first = BrandPalette.luminance(grads.first[/#[0-9A-F]{6}/])
    last  = BrandPalette.luminance(grads.last[/#[0-9A-F]{6}/])
    assert_operator first, :>, last, "the ramp should run light to dark"
  end

  test "an invalid primary yields no ramp rather than a broken gradient" do
    assert_empty BrandPalette.tile_gradients("not-a-colour")
    assert_empty BrandPalette.tile_gradients(nil)
  end

  test "the tiles reach the editor and the player when it is on" do
    @survey.update!(brand_answer_tint: true)
    sign_in

    get survey_path(@survey)
    assert_response :success
    assert_includes response.body, "--choice-bg-1", "the editor feed must carry the tints"
    assert_includes response.body, "--choice-bg-6"

    @survey.update!(publish_token: SecureRandom.hex(8))
    get play_survey_path(@survey.publish_token)
    assert_response :success
    assert_includes response.body, "--choice-bg-1", "respondents must see the branded tiles"
  end

  test "off by default, and then nothing is emitted" do
    refute @survey.brand_answer_tint?
    sign_in
    get survey_path(@survey)

    assert_response :success
    refute_includes response.body, "--choice-bg-",
                    "the stock pastels must come from the stylesheet, not be restated"
  end

  test "the editor toggles it through the same PATCH as the colours" do
    sign_in
    patch survey_path(@survey), params: { brand_answer_tint: true }.to_json,
          headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success
    assert @survey.reload.brand_answer_tint?

    patch survey_path(@survey), params: { brand_answer_tint: false }.to_json,
          headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success
    refute @survey.reload.brand_answer_tint?
  end

  test "both the create flow and the Design panel offer the choice" do
    sign_in
    get new_survey_path
    assert_response :success
    assert_select "input[name='brand_answer_tint'][type='checkbox']", 1

    get survey_path(@survey)
    assert_select "[data-brand-palette-target='tintToggle']", 1
  end

  test "the Ruby and JS ramps use the same steps" do
    js = File.read(Rails.root.join("app/javascript/lib/brand_palette.js"))
    steps = js[/TINT_STEPS = \[(.*?)\]/m, 1].to_s.scan(/[\d.]+/).map(&:to_f)

    assert_equal BrandPalette::TINT_STEPS, steps,
                 "the live preview would otherwise show different tiles than the server renders"
  end
end
