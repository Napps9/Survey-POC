require "application_system_test_case"

# The very first question a fresh account types.
#
# It crosses the one seam no other test walks: there is no thread yet, so the
# composer's send() has to create one via a full-page form POST, the question
# rides the redirect as a param, and the Stimulus controller on the NEW page
# has to pick it up and actually ask it. This used to silently discard the
# text — the form posted, the page reloaded onto an empty thread, and whatever
# was typed was gone. Only a browser exercises that whole chain.
class AskVertoComposeTest < ApplicationSystemTestCase
  def setup
    super
    @org  = Organisation.create!(name: "Anglo American Foundation", slug: "avq-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Avq", email_address: "avq-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(
      title: "Valparaíso Youth Pulse", theme: "Climate Action", audience_age: "adults",
      key_insight: "k", default_locale: "en", locales: [ "en" ], cards: []
    )
    # A citable corpus, so the page is in its ready state rather than the
    # empty-corpus one.
    @entry = CorpusEntry.create!(survey: @survey, organisation: @org,
                                 review_status: "approved", opted_in_at: 1.day.ago,
                                 response_count: 2648)
    @entry.corpus_questions.create!(
      cid: "c_worry", position: 0, card_type: "multiple_choice", theme: "Climate Action",
      question_text: "How worried are you about climate change?",
      response_count: 2648, distribution: { "Very worried" => 864, "Somewhat worried" => 1275 }
    )
  end

  # Streams a fixed answer; the test is about the journey, not the words.
  class FakeChat
    def call(messages:, scope: {}, &emit)
      emit&.call(t: "token", text: "Worry is high across the corpus.")
      emit&.call(t: "done", citations: [])
      { text: "Worry is high across the corpus.", citations: [] }
    end
  end

  test "the first question survives thread creation and streams an answer" do
    stub_method(AskVertoChat, :new, ->(*) { FakeChat.new }) do
      sign_in_as(@user)
      visit ask_path
      dismiss_cookie_banner

      find(".ask-composer textarea").fill_in(with: "Are young people worried?")
      find(".ask-composer textarea").send_keys(:enter)

      # The question survives as the user bubble on the newly created thread,
      # and the (scripted) answer streams in after it.
      assert_text "Are young people worried?", wait: 5
      assert_text "Worry is high across the corpus.", wait: 5
    end

    created = @org.ask_threads.order(:id).last
    assert_equal %w[user assistant], created.ask_messages.map(&:role)
    assert_equal "Are young people worried?", created.ask_messages.first.text
    assert_no_match(/[?&]q=/, current_url, "the carried question is scrubbed from the URL")
  end

  # Streams nothing at all — the shape of a turn the server killed before it
  # could write anything, which used to leave a permanently empty bubble.
  class SilentChat
    def call(messages:, scope: {}, &emit)
      { text: "", citations: [] }
    end
  end

  test "a stream that says nothing shows the error and releases the composer" do
    stub_method(AskVertoChat, :new, ->(*) { SilentChat.new }) do
      sign_in_as(@user)
      visit ask_path
      dismiss_cookie_banner

      find(".ask-composer textarea").fill_in(with: "Anything in there?")
      find(".ask-composer textarea").send_keys(:enter)

      assert_text "Anything in there?", wait: 5
      assert_text I18n.t("js.ask.error"), wait: 5

      # The turn failed but the composer recovered: a second question sends,
      # which is exactly what a wedged _loading flag used to prevent.
      assert_no_selector ".ask-send[disabled]"
      find(".ask-composer textarea").fill_in(with: "Still there?")
      find(".ask-composer textarea").send_keys(:enter)
      assert_text "Still there?", wait: 5
    end
  end

  test "a refused turn shows the server's own explanation" do
    thread = @org.ask_threads.create!(user: @user)
    thread.ask_messages.create!(role: "user", text: "Earlier question")
    thread.ask_messages.create!(role: "assistant", text: "Earlier answer.")

    stub_method(LimitsConcurrentStreams::POOL, :acquire, false) do
      sign_in_as(@user)
      visit ask_path(thread_id: thread.id)
      dismiss_cookie_banner

      find(".ask-composer textarea").fill_in(with: "One more?")
      find(".ask-composer textarea").send_keys(:enter)

      # The 503's plain-text body, verbatim — not the generic apology.
      assert_text LimitsConcurrentStreams::BUSY_MESSAGE, wait: 5
    end
  end
end
