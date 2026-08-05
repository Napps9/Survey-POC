require "test_helper"

# A Verto-level typeface, picked in the Design panel (and the create wizard's
# final step) beside the brand colours. The value reaches an inline `style`
# attribute, so it is allowlisted like every other creator-supplied style.
class BrandFontTest < ActionDispatch::IntegrationTest
  def setup
    @org  = Organisation.create!(name: "Font", slug: "fnt-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "F", email_address: "fnt-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Font", theme: "Sports", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "multiple_choice", "cid" => "c1", "text" => "Q", "options" => %w[a b] } ]
    )
  end

  def sign_in
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
  end

  test "only a known font token is accepted" do
    assert_equal "font-poppins", Survey.sanitize_brand_font("font-poppins")
    assert_nil Survey.sanitize_brand_font("font-comic-sans")
    assert_nil Survey.sanitize_brand_font("'; background: url(evil)")
    assert_nil Survey.sanitize_brand_font("")
    assert_nil Survey.sanitize_brand_font(nil)
  end

  test "every offered font is one the rich-text toolbar already loads" do
    assert_equal RichTextSanitizer::FONT_CLASSES.sort, Survey::BRAND_FONTS.keys.sort,
                 "a Verto font must be a family that's already self-hosted — anything " \
                 "else means a new webfont request and a CSP change"
    Survey::BRAND_FONTS.each_value do |meta|
      assert meta[:label].present?
      assert meta[:stack].present?
    end
  end

  test "the editor saves a font through the same PATCH as the colours" do
    sign_in
    patch survey_path(@survey), params: { brand_font: "font-anton" }.to_json,
          headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :success
    assert_equal "font-anton", @survey.reload.brand_font
  end

  test "an unknown font is dropped rather than stored" do
    sign_in
    patch survey_path(@survey), params: { brand_font: "font-evil" }.to_json,
          headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :success
    assert_nil @survey.reload.brand_font
  end

  test "the chosen font reaches the editor, the preview and the player" do
    @survey.update!(brand_font: "font-lora")
    # The stack's quotes are HTML-escaped inside the style attribute (the
    # browser decodes them), so match on the parsed attribute, not the source.
    carries_font = lambda do |body|
      Nokogiri::HTML(body).css("[style*='--verto-font']").any? do |el|
        el["style"].include?("--verto-font") && el["style"].include?("Lora")
      end
    end

    sign_in
    get survey_path(@survey)
    assert_response :success
    assert carries_font.call(response.body), "the editor feed must carry the font"

    @survey.update!(publish_token: SecureRandom.hex(8))
    get play_survey_path(@survey.publish_token)
    assert_response :success
    assert carries_font.call(response.body), "respondents must see the Verto's font"
  end

  test "a Verto on the default font emits no font variable at all" do
    sign_in
    get survey_path(@survey)

    assert_response :success
    refute_includes response.body, "--verto-font",
                    "the default must fall through to the stylesheet, not restate itself"
  end

  test "the Design panel and the create wizard both offer the picker" do
    sign_in
    get survey_path(@survey)
    assert_select "select.brand-font-select[data-brand-palette-target='fontSelect']", 1
    assert_select "select.brand-font-select option", { count: Survey::BRAND_FONTS.size + 1 },
                  "every font plus the default"

    get new_survey_path
    assert_response :success
    assert_select "select[name='brand_font']", 1
  end
end
