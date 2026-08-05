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

  test "headings can take a second face, and follow the body when unset" do
    sign_in
    patch survey_path(@survey),
          params: { brand_font: "font-lora", brand_font_heading: "font-anton" }.to_json,
          headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success
    @survey.reload
    assert_equal "font-lora",  @survey.brand_font
    assert_equal "font-anton", @survey.brand_font_heading

    get survey_path(@survey)
    body = Nokogiri::HTML(response.body)
    styled = body.css("[style*='--verto-font']").map { |el| el["style"] }.join(" ")
    assert_includes styled, "--verto-font-heading", "headings need their own variable"
    assert_includes styled, "Anton"
    assert_includes styled, "Lora"
  end

  test "a Verto with only a body font emits no heading variable, so headings follow it" do
    @survey.update!(brand_font: "font-lora")
    sign_in
    get survey_path(@survey)

    assert_response :success
    refute_includes response.body, "--verto-font-heading",
                    "an empty heading variable would beat the CSS fallback to the body face"
  end

  # The create flow is a different path to the editor's PATCH: the wizard
  # posts to #generate, which parks a payload for BuildVertoJob to turn into a
  # Verto. A branding field dropped at either seam looks fine in the wizard and
  # then arrives unstyled, so both are asserted.
  test "the wizard hands both fonts and the icon colours to the build" do
    sign_in
    post generate_survey_path, params: {
      theme: "Community safety", audience_age: "adults", key_insight: "what helps",
      brand_font: "font-lora", brand_font_heading: "font-anton", brand_answer_tint: "1",
      brand_palette: { "primary" => "#8B5CF6" }
    }

    build = @org.verto_builds.order(:id).last
    assert build, "the wizard should have parked a build"
    assert_equal "font-lora",  build.payload["brand_font"]
    assert_equal "font-anton", build.payload["brand_font_heading"]
    assert_equal true,         build.payload["brand_answer_tint"]
  end

  test "the build maps all three onto the Verto it creates" do
    # A Common-Questions-only deck (blank key_insight) is BuildVertoJob's
    # no-Claude branch, so this exercises the real mapping without the API.
    build = @org.verto_builds.create!(user: @user, payload: {
      "theme" => "Community safety", "audience_age" => "adults", "key_insight" => "",
      "common_cards" => [ { "type" => "multiple_choice", "text" => "Q", "options" => %w[a b] } ],
      "default_locale" => "en", "locales" => [ "en" ],
      "brand_font" => "font-lora", "brand_font_heading" => "font-anton",
      "brand_answer_tint" => true
    })

    survey = BuildVertoJob.new.send(:create_survey, build)

    assert_equal "font-lora",  survey.brand_font
    assert_equal "font-anton", survey.brand_font_heading
    assert survey.brand_answer_tint?, "the icon-colour choice must reach the Verto"
  end

  test "the Design panel and the create wizard both offer the picker" do
    sign_in
    get survey_path(@survey)
    assert_select "select.brand-font-select[data-brand-palette-target='fontSelect']", 1
    assert_select "select.brand-font-select[data-brand-palette-target='headingFontSelect']", 1

    get new_survey_path
    assert_response :success
    assert_select "select[name='brand_font']", 1
    assert_select "select[name='brand_font_heading']", 1
  end
end
