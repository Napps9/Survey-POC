require "test_helper"

# The third membership role. A viewer shares Vertos and sees their results,
# and can't create or edit anything: no editor, no creation door, no
# publish/unpublish/test-mode, no settings, no Common Question sets of their
# own. What they CAN reach is exactly what the dashboard offers them — Share,
# Results, Preview — and the read-only Share panel behind the first.
#
# Every refusal is checked at the controller, not the view: the views hide
# the buttons on the same predicate (can_edit_vertos?), but a URL typed by
# hand has to be refused too, and a fetch() asking for JSON has to be refused
# in JSON.
class ViewerRoleTest < ActionDispatch::IntegrationTest
  def setup
    @org    = Organisation.create!(name: "Viewer Co", slug: "viewer-#{SecureRandom.hex(3)}")
    @admin  = make_user("admin")
    @member = make_user("member")
    @viewer = make_user("viewer")
    @org.memberships.create!(user: @admin,  role: "admin")
    @org.memberships.create!(user: @member, role: "member")
    @org.memberships.create!(user: @viewer, role: "viewer")

    @live = @org.surveys.create!(
      title: "Live one", theme: "Live", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      publish_token: SecureRandom.hex(8), published_at: Time.current,
      cards: [ { "cid" => "c1", "type" => "multiple_choice", "text" => "Colour?", "options" => %w[Blue Green] } ]
    )
    @live.responses.create!(session_token: SecureRandom.uuid, status: "completed", locale: "en", answered: true,
                            answers: { "0" => { "type" => "multiple_choice", "value" => "Blue" } })
    @live.survey_links.create!(name: "Newsletter", slug: "newsletter-#{SecureRandom.hex(2)}")

    @draft = @org.surveys.create!(title: "Draft one", theme: "Draft", audience_age: "all", key_insight: "k",
                                  default_locale: "en", locales: [ "en" ])
    @set   = @org.common_question_sets.create!(name: "Set", theme: "T", key_insight: "k", default_locale: "en")
  end

  def make_user(tag)
    User.create!(name: tag.capitalize, email_address: "#{tag}-#{SecureRandom.hex(3)}@test.com",
                 password: "verylongpassword")
  end

  def sign_in(user)
    delete session_path
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def viewer_message = I18n.t("flash.organisation_scope.viewer_read_only")

  # A refusal in the language the request was made in.
  def assert_refused_as_viewer(door, json: false)
    if json
      assert_response :forbidden, "#{door}: expected a JSON 403"
      body = JSON.parse(response.body)
      assert_equal false, body["ok"], door
      assert_equal viewer_message, body["error"], door
    else
      assert_redirected_to root_path, "#{door} was not refused"
      assert_equal viewer_message, flash[:alert], "#{door} refused without the viewer message"
    end
  end

  # ── The model and the constraint ──────────────────────────────────────────

  test "viewer is a real role the database accepts, and nothing else is" do
    assert_equal %w[viewer member admin], Membership::ROLES
    assert_equal Membership::ROLES.sort, Membership.roles.values.sort
    assert Membership.find_by(user: @viewer, organisation: @org).viewer?

    other = make_user("stray")
    assert_raises(ActiveRecord::StatementInvalid) do
      Membership.connection.execute(
        "INSERT INTO memberships (user_id, organisation_id, role, created_at, updated_at) " \
        "VALUES (#{other.id}, #{@org.id}, 'owner', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
      )
    end
  end

  test "editing scope leaves viewers out" do
    assert_equal [ @admin, @member ].map(&:id).sort, @org.memberships.editing.pluck(:user_id).sort
  end

  # ── The dashboard ─────────────────────────────────────────────────────────

  test "the dashboard offers a viewer Share, Results and Preview but no way to edit or create" do
    sign_in @viewer
    get root_path
    assert_response :success

    assert_match %(data-panel-url="#{share_survey_path(@live)}"), response.body, "Share is missing for a live Verto"
    assert_match %(href="#{survey_results_path(@live)}"), response.body, "Results is missing"
    assert_match %(href="#{preview_survey_path(@live)}"), response.body, "Preview is missing"
    assert_match %(href="#{preview_survey_path(@draft)}"), response.body, "Preview is missing for the draft"

    refute_match %(href="#{survey_path(@live)}"),  response.body, "Edit still leads to the editor"
    refute_match %(href="#{survey_path(@draft)}"), response.body, "Edit still leads to the editor"
    refute_match %r{action="/surveys/\d+/publish"}, response.body, "Publish is still offered"
    refute_match %r{action="/surveys/\d+/duplicate"}, response.body, "Duplicate is still offered"
    refute_match %r{href="/surveys/new"}, response.body, "Create still linked"
    refute_match %r{href="/templates"},   response.body, "Templates still linked"
    refute_match 'data-create-menu-target="modal"', response.body, "the create modal is still in the DOM"
    refute_match "create-menu#open", response.body
    refute_match "bulk-select#toggle", response.body, "bulk archive is admin-only"
  end

  test "a member still gets Edit and Publish, and now the Share button too" do
    sign_in @member
    get root_path
    assert_response :success
    assert_match %(href="#{survey_path(@live)}"), response.body
    assert_match %r{action="/surveys/#{@draft.id}/publish"}, response.body
    assert_match %(data-panel-url="#{share_survey_path(@live)}"), response.body
  end

  test "the empty dashboard tells a viewer to wait for a colleague, not for Playverto" do
    # destroy!, not archive: an archived Verto is still on the dashboard.
    @org.surveys.each(&:destroy!)
    sign_in @viewer
    get root_path
    assert_response :success
    assert_match ERB::Util.html_escape(I18n.t("dashboard.empty_body_viewer")), response.body
    refute_match ERB::Util.html_escape(I18n.t("dashboard.empty_body_managed")), response.body
    refute_match I18n.t("dashboard.empty_cta"), response.body
  end

  test "the command palette sends a viewer to results, not the editor" do
    sign_in @viewer
    get root_path
    assert_match %(href="#{survey_results_path(@live)}"\n               class="command-palette-item"), response.body
  end

  # ── Sharing ───────────────────────────────────────────────────────────────

  test "a viewer opens the Share panel read-only" do
    sign_in @viewer
    get share_survey_path(@live)
    assert_response :success

    assert_match play_survey_url(@live.public_link_key), response.body, "the play link is the point"
    assert_match "Newsletter", response.body, "named links are listed"
    assert_match %(href="#{qr_survey_path(@live, format: :png)}"), response.body, "QR download stays"
    assert_match "share-modal#nativeShare", response.body

    refute_match %(action="#{survey_links_path(@live)}"), response.body, "the add-link form is still drawn"
    refute_match %r{action="/surveys/#{@live.id}/links/\d+"}, response.body, "link rename/recall/delete forms still drawn"
    refute_match %(action="#{survey_settings_path(@live)}"), response.body, "the custom-URL form is still drawn"
    refute_match %(action="#{unpublish_survey_path(@live, return_to: "share")}"), response.body, "Unpublish still drawn"
    refute_match %(action="#{test_mode_survey_path(@live)}"), response.body, "Test Mode still drawn"
    refute_match %(action="#{test_link_survey_path(@live, return_to: "share")}"), response.body, "Test link still drawn"
  end

  test "a member's Share panel is read-only too; an admin's carries the forms" do
    sign_in @member
    get share_survey_path(@live)
    assert_response :success
    refute_match %(action="#{survey_links_path(@live)}"), response.body

    sign_in @admin
    get share_survey_path(@live)
    assert_response :success
    assert_match %(action="#{survey_links_path(@live)}"), response.body
    assert_match %(action="#{unpublish_survey_path(@live, return_to: "share")}"), response.body
  end

  test "the link mutations behind the panel stay admin-only for a viewer" do
    sign_in @viewer
    link = @live.survey_links.first

    assert_no_difference "SurveyLink.count" do
      post survey_links_path(@live), params: { name: "Sneaky" }
      assert_redirected_to root_path
      delete survey_link_path(@live, link)
      assert_redirected_to root_path
    end
    patch survey_link_path(@live, link), params: { name: "Renamed" }
    assert_redirected_to root_path
    assert_equal "Newsletter", link.reload.name
  end

  test "a viewer can preview and download the QR" do
    sign_in @viewer
    get preview_survey_path(@live)
    assert_response :success
    get qr_survey_path(@live, format: :png)
    assert_response :success
  end

  # ── Results ───────────────────────────────────────────────────────────────

  test "a viewer sees results, compare data and the exports" do
    sign_in @viewer
    get survey_results_path(@live)
    assert_response :success
    assert_match "Colour?", response.body

    get survey_results_compare_path(@live)
    assert_response :success
    assert JSON.parse(response.body)["ok"]

    get survey_results_export_path(@live, kind: "responses")
    assert_response :success
    assert_match %r{text/csv}, response.media_type
  end

  test "the results page draws a viewer no editor link, no report editing and no results-share controls" do
    sign_in @viewer
    get survey_results_path(@live)
    assert_response :success

    refute_match %(href="#{survey_path(@live)}"), response.body, "editor link still drawn"
    assert_match %(href="#{root_path}"), response.body, "no way back to the dashboard"
    refute_match "report-export#edit", response.body, "report Edit still drawn"
    refute_match "report-export#save", response.body, "report Save still drawn"
    refute_match %(action="#{results_share_survey_path(@live)}"), response.body, "results-share buttons still drawn"
    refute_match %(href="#{survey_respondent_data_path(@live)}"), response.body, "respondent data is admin-only"
  end

  test "an admin's results page keeps the editor link and the results-share controls" do
    sign_in @admin
    get survey_results_path(@live)
    assert_response :success
    assert_match %(href="#{survey_path(@live)}"), response.body
    assert_match %(action="#{results_share_survey_path(@live)}"), response.body
    assert_match "report-export#edit", response.body
  end

  test "hand-editing the report is refused, in JSON" do
    sign_in @viewer
    patch survey_results_report_path(@live), params: { markdown: "# Mine now" }, as: :json
    assert_refused_as_viewer(:results_report_update, json: true)
    assert_nil @live.reload.results_report
  end

  test "a viewer may not regenerate a report that already exists, but a plain open still replays it" do
    @live.update_columns(results_report: "# Theirs", results_report_response_count: 1)
    sign_in @viewer

    get survey_results_report_stream_path(@live, regenerate: 1, goal: "mine")
    assert_response :forbidden
    assert_equal viewer_message, response.body
    assert_equal "# Theirs", @live.reload.results_report

    get survey_results_report_stream_path(@live)
    assert_response :success
    assert_match "Theirs", response.body

    get survey_results_path(@live)
    refute_match "report-export#regenerate", response.body, "Regenerate is still drawn for a viewer"
  end

  # ── Editing ───────────────────────────────────────────────────────────────

  # Every editing door on SurveysController and its satellites. The coverage
  # test at the bottom is what stops the NEXT one being left off this list.
  def attempt_every_editing_door
    get survey_path(@live)
    yield :editor, false
    patch survey_path(@live), params: { title: "Changed" }.to_json, headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }
    yield :update, true
    post publish_survey_path(@draft)
    yield :publish, false
    post unpublish_survey_path(@live)
    yield :unpublish, false
    post test_link_survey_path(@draft)
    yield :enable_test_link, false
    delete test_link_survey_path(@draft)
    yield :disable_test_link, false
    post test_mode_survey_path(@live)
    yield :convert_to_test_mode, false
    post survey_settings_path(@live), params: { share_enabled: "0" }
    yield :update_settings, false
    post survey_languages_path(@draft), params: { locales: [ "fr" ] }
    yield :update_languages, false
    post audience_country_survey_path(@draft), params: { audience_country: "GB" }
    yield :update_audience_country, false
    post card_image_survey_path(@draft), params: { image: "data:image/png;base64,AA==" }, as: :json
    yield :card_image, true
    post card_lottie_survey_path(@draft), params: { url: "https://lottiefiles.com/x" }, as: :json
    yield :card_lottie, true
    post moderate_image_survey_path(@draft), params: { image: "data:image/png;base64,AA==" }, as: :json
    yield :moderate_image, true
    get pexels_search_survey_path(@draft, q: "sky"), as: :json
    yield :pexels_search, true
    post shuffle_survey_assets_path(@draft)
    yield :shuffle_assets, false
    get setup_status_survey_path(@draft), as: :json
    yield :setup_status, true
    post generate_survey_card_path(@draft), params: { prompt: "x" }, as: :json
    yield :generate_card, true
    post generate_survey_flow_path(@draft), params: { prompt: "x" }.to_json, headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }
    yield :generate_flow, true
    post restore_survey_card_path(@draft), params: { cid: "c1" }, as: :json
    yield :restore_card, true
    post optimise_survey_card_path(@draft), params: { text: "x" }, as: :json
    yield :optimise_card, true
    post render_survey_card_path(@draft), params: { card: {} }, as: :json
    yield :render_card, true
    post demographic_survey_card_path(@draft), params: { kind: "age" }, as: :json
    yield :add_demographic_card, true
    post survey_waves_path(@live), params: { label: "Wave 2" }
    yield :wave_create, false
    get image_appeals_survey_path(@draft), as: :json
    yield :image_appeals_index, true
    post image_appeal_survey_path(@draft), params: { image: "data:image/png;base64,AA==" }, as: :json
    yield :image_appeal_create, true
  end

  test "a viewer is refused at every editing door, in the language it was asked in" do
    sign_in @viewer
    before = [ @live.reload.attributes, @draft.reload.attributes ]

    attempt_every_editing_door do |door, json|
      assert_refused_as_viewer(door, json: json)
    end

    assert_equal before, [ @live.reload.attributes, @draft.reload.attributes ], "something changed anyway"
    assert_equal 0, @live.survey_waves.count
  end

  test "a member passes every one of those doors the gate itself" do
    @member.update!(email_verified_at: Time.current) # publishing's own gate, not this one
    sign_in @member
    get survey_path(@draft)
    assert_response :success, "the editor should open for a member"
    post publish_survey_path(@draft)
    assert_redirected_to survey_path(@draft)
    assert @draft.reload.published?
  end

  test "the flow-generation poll is refused for a viewer in JSON" do
    generation = @draft.flow_generations.create!(user: @viewer, payload: { "prompt" => "x" }, status: "pending")
    sign_in @viewer
    get flow_generation_path(generation), as: :json
    assert_refused_as_viewer(:flow_generation, json: true)
  end

  # ── Creating ──────────────────────────────────────────────────────────────

  test "a viewer is refused every creation door with the viewer message, not the managed-account one" do
    build = @org.verto_builds.create!(user: @admin, kind: "generate", payload: {})
    sign_in @viewer

    assert_no_difference [ "Survey.count", "VertoBuild.count" ] do
      get new_survey_path
      assert_refused_as_viewer(:new_survey)
      post generate_survey_path, params: { theme: "T", audience_age: "a", key_insight: "k" }
      assert_refused_as_viewer(:generate)
      post import_pdf_survey_path
      assert_refused_as_viewer(:import_pdf)
      post import_manual_survey_path, params: { manual_questions: "Q1?" }
      assert_refused_as_viewer(:import_manual)
      post import_google_form_survey_path, params: { google_form_url: "https://docs.google.com/forms/d/x/edit" }
      assert_refused_as_viewer(:import_google_form)
      post create_blank_survey_path
      assert_refused_as_viewer(:create_blank)
      post finalize_import_survey_path
      assert_refused_as_viewer(:finalize_import)
      get resume_import_path(build)
      assert_refused_as_viewer(:resume_import)
      post duplicate_survey_path(@live)
      assert_refused_as_viewer(:duplicate)
      get survey_templates_path
      assert_refused_as_viewer(:templates_index)
      post survey_template_path("nps")
      assert_refused_as_viewer(:templates_create)
      get verto_build_path(build)
      assert_refused_as_viewer(:verto_build)
      get verto_build_path(build, format: :json)
      assert_refused_as_viewer(:verto_build_json, json: true)
    end
  end

  test "a viewer in a managed account is refused as a viewer, and a member there as managed" do
    @org.update!(verto_creation_enabled: false)

    sign_in @viewer
    get new_survey_path
    assert_refused_as_viewer(:new_survey)

    sign_in @member
    get new_survey_path
    assert_redirected_to root_path
    assert_equal I18n.t("flash.organisation_scope.verto_creation_disabled"), flash[:alert]
  end

  # ── Common Questions ──────────────────────────────────────────────────────

  test "a viewer sees Common Question sets but can't start or change one" do
    sign_in @viewer

    get common_question_sets_path
    assert_response :success
    refute_match %(href="#{new_common_question_set_path}"), response.body, "Create-a-set still linked"

    @live.update!(cards: @live.cards + [ { "cid" => "cq1", "type" => "multiple_choice", "text" => "Set Q",
                                           "options" => %w[A B], "common_question_set_id" => @set.id } ])
    get common_question_set_path(@set)
    assert_response :success
    assert_match %(href="#{survey_results_path(@live)}"), response.body, "an attached Verto should lead to its results"
    refute_match %(href="#{survey_path(@live)}"), response.body, "an attached Verto still leads to the editor"
    refute_match %(action="#{add_question_common_question_set_path(@set)}"), response.body
    refute_match %(action="#{common_question_set_path(@set)}"), response.body, "the delete-set form is still drawn"
    refute_match %r{/questions/\d+}, response.body, "a per-question form is still drawn"

    get results_common_question_set_path(@set)
    assert_response :success

    assert_no_difference "CommonQuestionSet.count" do
      get new_common_question_set_path
      assert_refused_as_viewer(:cqs_new)
      post common_question_sets_path, params: { common_question_set: { name: "N", theme: "T", key_insight: "k" } }
      assert_refused_as_viewer(:cqs_create)
      post generate_common_question_sets_path, params: { theme: "T", key_insight: "k" }
      assert_refused_as_viewer(:cqs_generate)
    end
    assert_no_difference "CommonQuestion.count" do
      post add_question_common_question_set_path(@set), params: { text: "New?" }
      assert_refused_as_viewer(:cqs_add_question)
    end
    delete common_question_set_path(@set)
    assert_refused_as_viewer(:cqs_destroy)
    assert @set.reload.persisted?
  end

  # ── Admin surfaces stay admin-only ────────────────────────────────────────

  test "a viewer is not an admin" do
    sign_in @viewer
    get organisation_memberships_path(@org)
    assert_redirected_to root_path
    assert_equal I18n.t("flash.organisation_scope.not_authorised"), flash[:alert]

    delete survey_path(@live)
    assert_redirected_to root_path
    assert_nil @live.reload.deleted_at
  end

  # ── Inviting ──────────────────────────────────────────────────────────────

  test "the invite form offers Viewer, and an invite as viewer lands a viewer membership" do
    sign_in @admin
    get new_organisation_invite_path(@org)
    assert_response :success
    assert_match %(<option value="viewer">), response.body
    assert_match %(<option selected="selected" value="member">), response.body, "Member stays the default"

    email = "newviewer-#{SecureRandom.hex(2)}@test.com"
    post organisation_invites_path(@org), params: { email_address: email, role: "viewer" }
    assert_response :success
    invite = @org.invites.pending.find_by!(email_address: email)
    assert_equal "viewer", invite.role

    delete session_path
    post accept_invite_path(invite.token), params: { name: "New", password: "abrandnewpassword1", password_confirmation: "abrandnewpassword1" }
    assert_redirected_to root_path
    assert @org.memberships.find_by!(user: User.find_by!(email_address: email)).viewer?
  end

  test "an unknown invite role still falls back to member" do
    sign_in @admin
    email = "owner-#{SecureRandom.hex(2)}@test.com"
    post organisation_invites_path(@org), params: { email_address: email, role: "owner" }
    assert_equal "member", @org.invites.pending.find_by!(email_address: email).role
  end

  test "the Members page labels a viewer" do
    sign_in @admin
    get organisation_memberships_path(@org)
    assert_response :success
    assert_match %r{>\s*viewer\s*</span>}, response.body
  end

  # ── The half that stops the NEXT editing route being forgotten ───────────
  #
  # Same idea as verto_creation_gate_test's coverage assertion, one level
  # up: every public action on SurveysController must be behind the
  # creation gate, the editing gate or require_admin!, OR be on the short
  # list of what a viewer is for. A new action that is none of those is a
  # door nobody decided about.
  VIEWER_ALLOWED = %i[ index preview qr results results_compare ].freeze

  test "every SurveysController action is either gated or deliberately open to a viewer" do
    source     = File.read(Rails.root.join("app/controllers/surveys_controller.rb"))
    admin_only = source.scan(/before_action :require_admin!,\s*only: \[([^\]]*)\]/)
                       .flatten.flat_map { |list| list.scan(/:([a-z_]+)/).flatten.map(&:to_sym) }
    gated      = SurveysController.verto_creation_actions + SurveysController.verto_editing_actions + admin_only

    # Routed actions, not action_methods: the latter also lists the public
    # helper-style methods (editing_locked_message, play_settings...) that no
    # request can reach.
    routed = Rails.application.routes.routes.filter_map { |r|
      r.requirements[:action]&.to_sym if r.requirements[:controller] == "surveys"
    }.uniq
    assert_operator routed.size, :>, 30, "expected to find the surveys routes; found #{routed.size}"

    undecided = routed - gated - VIEWER_ALLOWED
    assert_empty undecided,
                 "these SurveysController actions are open to a viewer without anyone deciding so — " \
                 "gate them (gate_verto_editing / gate_verto_creation / require_admin!) or add them to " \
                 "VIEWER_ALLOWED here: #{undecided.inspect}"

    stray = VIEWER_ALLOWED & gated
    assert_empty stray, "listed as viewer-allowed but also gated: #{stray.inspect}"
  end
end
