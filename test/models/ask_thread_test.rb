require "test_helper"

class AskThreadTest < ActiveSupport::TestCase
  def setup
    @org  = Organisation.create!(name: "T", slug: "att-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "T", email_address: "att-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @thread = @org.ask_threads.create!(user: @user)
  end

  test "prompt_messages carries the prose and never the markers" do
    @thread.ask_messages.create!(role: "user", text: "Are young people worried?")
    @thread.ask_messages.create!(
      role: "assistant",
      text: "Worry is high [[c:1]]. In their own words [[q:88]]: they are."
    )

    contents = @thread.prompt_messages.map { |m| m[:content] }

    assert_equal "Are young people worried?", contents.first
    assert_equal "Worry is high . In their own words : they are.", contents.last
    assert_no_match AskMessage::MARKER, contents.join,
      "a marker in history is numbered for a turn that is over — re-injected, it can " \
      "pass validation while citing the wrong live source"
  end

  test "prompt_messages drops a turn whose prose was only markers" do
    @thread.ask_messages.create!(role: "user", text: "q")
    @thread.ask_messages.create!(role: "assistant", text: "[[c:1]] [[q:88]]")

    messages = @thread.prompt_messages

    assert_equal [ "q" ], messages.map { |m| m[:content] },
      "stripping left no prose — an empty content block is an API 400 on the next turn"
  end

  test "prompt_messages drops an empty user row" do
    @thread.ask_messages.create!(role: "user", text: "")
    @thread.ask_messages.create!(role: "user", text: "real question")

    assert_equal [ "real question" ], @thread.prompt_messages.map { |m| m[:content] }
  end

  test "prompt_messages is bounded to the newest turns" do
    25.times { |i| @thread.ask_messages.create!(role: "user", text: "q#{i}") }

    messages = @thread.prompt_messages(limit: 20)

    assert_equal 20, messages.size
    assert_equal "q24", messages.last[:content]
  end

  test "display_title falls back to the opening question" do
    assert_equal "New thread", @thread.display_title

    @thread.ask_messages.create!(role: "user", text: "How worried are people about climate change?")
    assert_equal "How worried are people about climate change?", @thread.display_title

    @thread.update!(title: "Climate worry")
    assert_equal "Climate worry", @thread.display_title
  end

  test "prune! trims the oldest threads past the cap" do
    cap = AskThread::MAX_PER_ORGANISATION
    @thread.update_column(:updated_at, 2.days.ago)
    (cap + 2).times { |i| @org.ask_threads.create!(user: @user, updated_at: i.minutes.ago) }

    AskThread.prune!(@org)

    assert_equal cap, @org.ask_threads.count
    assert_nil AskThread.find_by(id: @thread.id), "the oldest thread goes first"
  end
end
