require "test_helper"

# Rich text end to end: formatted markup renders in editor and player,
# translations render plain, exports stay plain, and the autosave round trip
# keeps the html layer.
class RichTextRenderTest < ActionDispatch::IntegrationTest
  def setup
    @org  = Organisation.create!(name: "RT", slug: "rt-#{SecureRandom.hex(2)}")
    @user = User.create!(name: "U", email_address: "rt-#{SecureRandom.hex(2)}@test.com",
                         password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "S", theme: "Sports", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en", "fr" ],
      cards: [ { "type" => "multiple_choice", "text" => "Big question",
                 "text_html" => %(<span class="font-anton">Big</span> question),
                 "options" => [ "Bold pick", "Plain" ],
                 "options_html" => [ "<b>Bold pick</b>", nil ],
                 "i18n" => { "fr" => { "text" => "Grande question" } } },
               # The scenario's answer page is the multiple_choice list reused —
               # its rows must carry the same rich-text layer, or a font set on
               # one renders plain after reload and is dropped on the next save.
               { "type" => "scenario", "cid" => "sc", "text" => "A fork in the road",
                 "pages" => [ { "id" => "p1", "text" => "Once upon a time." } ],
                 "options" => [ "Go left", "Go right" ],
                 "options_html" => [ "<b>Go left</b>", nil ] } ]
    )
    @survey.update!(publish_token: SecureRandom.hex(8))
  end

  test "the player renders the formatted title and option" do
    get play_survey_path(@survey.publish_token)

    assert_response :success
    assert_select ".q-title span.font-anton", text: "Big"
    assert_select ".pick-text b", text: "Bold pick"
    assert_select ".book-page.is-answer .pick-text b", text: "Go left"
  end

  test "a translated view renders plain — a translation never wears primary markup" do
    get play_survey_path(@survey.publish_token, lang: "fr")

    assert_response :success
    assert_select ".q-title", text: "Grande question"
    assert_select ".q-title span.font-anton", 0
  end

  test "the editor marks rich regions and renders the stored formatting" do
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    @survey.update!(publish_token: nil)

    get survey_path(@survey)

    assert_response :success
    assert_select ".q-title[data-rich-text] span.font-anton", { minimum: 1 }
    # The option rows are regions too — this is what lets a creator put a font
    # on one option. The toolbar only ever appears inside [data-rich-text].
    assert_select ".pick-text[data-rich-text] b", text: "Bold pick"
    assert_select ".book-page.is-answer .pick-text[data-rich-text] b", text: "Go left"
    assert_select ".rich-text-toolbar", 1
  end

  test "the autosave round trip keeps equivalent html and drops tampered html" do
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    @survey.update!(publish_token: nil)

    patch survey_path(@survey),
          params: { cards: [ { "type" => "multiple_choice", "cid" => @survey.cards.first["cid"],
                               "text" => "Big question",
                               "text_html" => %(<span class="font-spectral">Big question</span>),
                               "options" => [ "Bold pick" ],
                               "options_html" => [ %(<b onclick="x()">Bold pick</b>) ] },
                             { "type" => "scenario", "cid" => "sc", "text" => "A fork in the road",
                               "pages" => [ { "id" => "p1", "text" => "Once upon a time." } ],
                               "options" => [ "Go left", "Go right" ],
                               "options_html" => [ %(<span class="font-poppins">Go left</span>), nil ] } ] }.to_json,
          headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :success
    card = @survey.reload.cards.first
    assert_equal %(<span class="font-spectral">Big question</span>), card["text_html"]
    assert_equal "<b>Bold pick</b>", card["options_html"][0], "the handler must be stripped"
    assert_equal %(<span class="font-poppins">Go left</span>), @survey.cards.second["options_html"][0],
                 "a font on a scenario answer must survive the save like any other option's"
  end

  test "the CSV export stays plain" do
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", locale: "en",
                              answers: { "0" => { "type" => "multiple_choice", "value" => "Bold pick" } })
    agg = Class.new { include AggregatesSurveyResults }.new
    responses = @survey.responses.where(status: "completed")
    export = ResultsExport.new(survey: @survey, responses: responses,
                               aggregated: agg.send(:aggregate_results, Array(@survey.cards), responses))

    flat = export.response_rows.flatten.join("\n")
    assert_includes flat, "Big question"
    assert_includes flat, "Bold pick"
    refute_match(/<span|<b>/, flat, "markup must never reach the spreadsheet")
  end
end
