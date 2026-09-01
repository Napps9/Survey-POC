require "test_helper"

class LoadTestSeederTest < ActiveSupport::TestCase
  def with_seed_flag(value)
    old = ENV["LOAD_TEST_SEED"]
    ENV["LOAD_TEST_SEED"] = value
    yield
  ensure
    old.nil? ? ENV.delete("LOAD_TEST_SEED") : ENV["LOAD_TEST_SEED"] = old
  end

  test "refuses to run without the explicit LOAD_TEST_SEED flag" do
    with_seed_flag(nil) do
      err = assert_raises(RuntimeError) { LoadTestSeeder.run!(responses: 1, io: StringIO.new) }
      assert_match(/LOAD_TEST_SEED=1/, err.message)
      assert_nil Organisation.find_by(slug: LoadTestSeeder::ORG_SLUG)
    end
  end

  test "seeds a published tokenised leaderboard Verto and N completed responses" do
    result = with_seed_flag("1") { LoadTestSeeder.run!(responses: 25, batch_size: 10, io: StringIO.new) }
    survey = result[:survey]

    assert_equal 25, result[:inserted]
    assert survey.published_at.present?
    assert survey.tokenisation_enabled?
    assert survey.leaderboard_enabled?
    assert_equal 25, survey.responses.count

    resp = survey.responses.order(:id).first
    assert resp.answered?
    assert_equal "completed", resp.status
    assert resp.player_key_digest.present?
    # Token totals are computed server-side from the stored answers, the same
    # way #submit does it — the leaderboard scan sums exactly this column.
    assert_equal TokenGrading.totals(survey.cards, resp.answers, survey.token_type_ids),
                 resp.token_totals
  end

  test "re-running appends to the same Verto instead of duplicating it" do
    with_seed_flag("1") do
      first = LoadTestSeeder.run!(responses: 5, io: StringIO.new)
      again = LoadTestSeeder.run!(responses: 5, io: StringIO.new)

      assert_equal first[:survey].id, again[:survey].id
      assert_equal 1, Organisation.where(slug: LoadTestSeeder::ORG_SLUG).count
      assert_equal 10, first[:survey].responses.count
      assert_equal 10, first[:survey].responses.distinct.count(:session_token)
    end
  end

  test "never deletes or mutates rows it did not create" do
    org = Organisation.create!(name: "Bystander", slug: "bystander-#{SecureRandom.hex(3)}")
    survey = org.surveys.create!(
      title: "Untouched", theme: "t", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "hi" } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
    survey.responses.create!(session_token: "bystander-row", answers: {}, status: "completed")
    before = survey.responses.order(:id).pluck(:id, :updated_at)

    with_seed_flag("1") { LoadTestSeeder.run!(responses: 3, io: StringIO.new) }

    assert_equal before, survey.responses.order(:id).pluck(:id, :updated_at)
    assert Organisation.exists?(org.id)
  end
end
