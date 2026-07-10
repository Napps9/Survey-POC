require "test_helper"

class TemplatesControllerTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "t-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "tpl-#{SecureRandom.hex(2)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  test "gallery renders and lists every template" do
    get survey_templates_path
    assert_response :success
    SurveyTemplates.all.each { |t| assert_includes response.body, t[:name] }
  end

  test "picking a template instantiates a draft Verto under the org and opens the editor" do
    template = SurveyTemplates.find("nps")

    assert_difference -> { @org.surveys.count }, 1 do
      post survey_template_path("nps")
    end

    survey = @org.surveys.order(:created_at).last
    assert_redirected_to survey_path(survey)
    assert_equal template[:name], survey.title
    assert_nil survey.publish_token, "a template Verto starts as an unpublished draft"

    # Carries the template's content cards plus the appended demographic tail.
    assert survey.cards.any? { |c| c["type"] == "welcome_card" }
    assert survey.cards.any? { |c| c["type"] == "nps" }
    assert survey.cards.any? { |c| c["demographic"] }
  end

  test "instantiation does not call any AI service" do
    # SurveyGenerator is the AI entrypoint; a template must never touch it.
    # Stub .new to hand back a fake whose #call flips a flag if ever invoked.
    called = false
    fake = Object.new
    fake.define_singleton_method(:call) { |*_a, **_k| called = true; {} }

    stub_method(SurveyGenerator, :new, -> { fake }) do
      post survey_template_path("csat")
    end
    assert_response :redirect
    assert_not called, "template instantiation must not invoke the AI generator"
  end

  test "an unknown template id redirects back with an alert and creates nothing" do
    assert_no_difference -> { @org.surveys.count } do
      post survey_template_path("does-not-exist")
    end
    assert_redirected_to survey_templates_path
    assert_equal I18n.t("templates.not_found"), flash[:alert]
  end

  test "the gallery requires authentication" do
    delete session_path
    get survey_templates_path
    assert_response :redirect
  end
end
