require "test_helper"

# A MANAGED account (Organisation#verto_creation_enabled false) has its Vertos
# built for it by the Playverto team, so every door into creating one is shut —
# while Playverto staff acting INSIDE that same account still get through,
# because they are the ones doing the building.
#
# The client user here is deliberately an ADMIN of the managed org: that is what
# proves the gate is a property of the ACCOUNT and not of the person's role.
class VertoCreationGateTest < ActionDispatch::IntegrationTest
  def setup
    @managed = Organisation.create!(name: "Managed Co", slug: "managed-#{SecureRandom.hex(3)}",
                                    verto_creation_enabled: false)
    @client  = User.create!(name: "Client", email_address: "client-#{SecureRandom.hex(3)}@test.com",
                            password: "verylongpassword")
    @managed.memberships.create!(user: @client, role: "admin")

    @open_org = Organisation.create!(name: "Open Co", slug: "open-#{SecureRandom.hex(3)}")
    @creator  = User.create!(name: "Creator", email_address: "creator-#{SecureRandom.hex(3)}@test.com",
                             password: "verylongpassword")
    @open_org.memberships.create!(user: @creator, role: "admin")

    # Jamie: a member of the managed org AND of the Playverto org.
    @playverto = Organisation.find_or_create_by!(slug: PlayvertoStaff::SLUG) { |o| o.name = "Playverto" }
    @staff = User.create!(name: "Jamie", email_address: "staff-#{SecureRandom.hex(3)}@test.com",
                          password: "verylongpassword")
    @managed.memberships.create!(user: @staff, role: "admin")
    @playverto.memberships.create!(user: @staff, role: "member")

    @survey = @managed.surveys.create!(title: "Built for them", theme: "T", audience_age: "a",
                                       key_insight: "k", default_locale: "en", locales: [ "en" ])
    @build = @managed.verto_builds.create!(user: @staff, kind: "generate", payload: {})
  end

  def sign_in(user)
    delete session_path
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  # Every creation door, in one place. A new route added without a gate should
  # break the coverage test below rather than slip through here unnoticed.
  def attempt_every_creation_door
    get new_survey_path
    yield :new_survey
    post generate_survey_path, params: { theme: "T", audience_age: "a", key_insight: "k" }
    yield :generate
    post import_pdf_survey_path
    yield :import_pdf
    post import_manual_survey_path, params: { text: "Q1?" }
    yield :import_manual
    post import_google_form_survey_path, params: { google_form_url: "https://docs.google.com/forms/d/x/edit" }
    yield :import_google_form
    post create_blank_survey_path
    yield :create_blank
    post finalize_import_survey_path
    yield :finalize_import
    get resume_import_path(@build)
    yield :resume_import
    post duplicate_survey_path(@survey)
    yield :duplicate
    get survey_templates_path
    yield :templates_index
    post survey_template_path("nps")
    yield :templates_create
    get verto_build_path(@build)
    yield :verto_build
  end

  test "a managed account cannot reach any Verto-creation route, even as an admin" do
    sign_in @client

    assert_no_difference [ "Survey.count", "VertoBuild.count" ] do
      attempt_every_creation_door do |door|
        assert_redirected_to root_path, "#{door} was not refused for a managed account"
        assert_equal I18n.t("flash.organisation_scope.verto_creation_disabled"), flash[:alert],
                     "#{door} refused without saying why"
      end
    end
  end

  # The wait screen is polled with an explicit .json extension. A 302 to a page
  # of HTML reads to that poller as a mystery failure rather than a refusal.
  test "the JSON build poller is refused in JSON, not redirected" do
    sign_in @client

    get verto_build_path(@build, format: :json)

    assert_response :forbidden
    body = JSON.parse(response.body)
    assert_equal false, body["ok"]
    assert_equal I18n.t("flash.organisation_scope.verto_creation_disabled"), body["error"]
  end

  test "Playverto staff can create inside the same managed account" do
    sign_in @staff
    post switch_organisation_path, params: { organisation_id: @managed.id }

    get new_survey_path
    assert_response :success

    assert_difference "Survey.count", 1 do
      post create_blank_survey_path
    end
  end

  test "an ordinary account is completely unaffected" do
    sign_in @creator

    get new_survey_path
    assert_response :success

    get survey_templates_path
    assert_response :success

    assert_difference "Survey.count", 1 do
      post create_blank_survey_path
    end
  end

  test "the dashboard offers a managed account no way to create" do
    sign_in @client
    get root_path
    assert_response :success

    refute_match %r{href="/surveys/new"}, response.body, "nav still links to the create wizard"
    refute_match %r{href="/templates"},   response.body, "nav still links to the template gallery"
    refute_match 'data-create-menu-target="modal"', response.body, "the create modal is still in the DOM"
    refute_match "create-menu#open", response.body, "a create trigger is still rendered"
    # Match the form action, not the label: window.I18N carries unrelated
    # editor strings containing the word "Duplicate".
    refute_match %r{action="/surveys/\d+/duplicate"}, response.body, "Duplicate is still offered"
  end

  test "the dashboard offers an ordinary account every way to create" do
    sign_in @creator
    @open_org.surveys.create!(title: "Theirs", theme: "T", audience_age: "a", key_insight: "k",
                              default_locale: "en", locales: [ "en" ])
    get root_path
    assert_response :success

    assert_match %r{href="/surveys/new"}, response.body
    assert_match 'data-create-menu-target="modal"', response.body
    assert_match %r{action="/surveys/\d+/duplicate"}, response.body
  end

  # A managed account with nothing yet must read as "not yet", not as broken.
  test "the empty state for a managed account explains rather than offering a CTA" do
    # delete_all, not destroy! — Survey soft-deletes, and a soft-deleted Verto
    # lands in the dashboard's "archived" list, which is not the empty state.
    Survey.where(id: @survey.id).delete_all
    sign_in @client
    get root_path
    assert_response :success

    assert_match I18n.t("dashboard.empty_title_managed"), response.body
    # Escaped: the copy contains an apostrophe, which ERB renders as &#39;.
    assert_match ERB::Util.html_escape(I18n.t("dashboard.empty_body_managed")), response.body
    refute_match I18n.t("dashboard.empty_cta"), response.body
    refute_match "create-menu#open", response.body
  end

  # The create-menu Stimulus controller dereferences its modal target on connect
  # when the reopen value is true. With the modal no longer rendered, arming it
  # would throw in the browser — so the view must never arm it.
  test "?open_import=1 does not arm the create menu for a managed account" do
    sign_in @client
    get root_path(open_import: 1)

    assert_response :success
    refute_match 'data-create-menu-reopen-value="true"', response.body
  end

  # ── The half that stops the NEXT creation route being forgotten ──────────
  #
  # Same intent as ai_spend_throttle_test's assertion against
  # SurveysController.ai_throttled_actions: read the controller source, find the
  # actions that actually mint a Survey or a VertoBuild, and require each to be
  # registered with the gate.
  CREATION_CALLS = /create_imported_survey!|enqueue_import|surveys\.create!|verto_builds\.create!|\.duplicate!/

  test "every SurveysController action that mints a Verto is gated" do
    registered = SurveysController.verto_creation_actions
    public_actions = SurveysController.action_methods

    current, unregistered = nil, []
    File.readlines(Rails.root.join("app/controllers/surveys_controller.rb")).each do |line|
      current = Regexp.last_match(1) if line =~ /^  def ([a-z_0-9]+[?!]?)/
      next if line.strip.start_with?("#")
      next unless current && line.match?(CREATION_CALLS)
      # Intersecting with action_methods drops the private helpers
      # (create_imported_survey!, enqueue_import) that contain the call itself.
      unregistered << current if public_actions.include?(current) && !registered.include?(current.to_sym)
    end

    assert_empty unregistered.uniq,
                 "these SurveysController actions create a Verto but are not passed to " \
                 "gate_verto_creation — a managed account could reach them: #{unregistered.uniq.inspect}"
  end

  test "the gate is registered on every controller that can mint a Verto" do
    assert_includes TemplatesController.verto_creation_actions, :create
    assert_includes TemplatesController.verto_creation_actions, :index
    assert_includes VertoBuildsController.verto_creation_actions, :show
  end

  # A rename would otherwise leave a filter registered against an action that no
  # longer exists — silently ungating the renamed one.
  test "every gated action is a real action on its controller" do
    missing = []
    { "SurveysController" => SurveysController,
      "TemplatesController" => TemplatesController,
      "VertoBuildsController" => VertoBuildsController }.each do |name, klass|
      klass.verto_creation_actions.each do |action|
        missing << "#{name}##{action}" unless klass.action_methods.include?(action.to_s)
      end
    end
    assert_empty missing, "gated actions that no longer exist: #{missing.inspect}"
  end
end
