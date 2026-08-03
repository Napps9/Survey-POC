require "test_helper"

# Guards the CSV → Verto reconstruction: the deck shape built from the export's
# column headers, and the per-type mapping of each respondent row into the
# `answers` hash the player/results code reads. Runs against a small fixture
# carved from the real UNYO export (test/fixtures/files/verto_import_sample.csv).
class VertoCsvImporterTest < ActiveSupport::TestCase
  FIXTURE        = Rails.root.join("test/fixtures/files/verto_import_sample.csv").to_s
  APPEND_FIXTURE = Rails.root.join("test/fixtures/files/verto_import_append.csv").to_s
  PASSWORD       = "import-test-passphrase"

  def import!
    VertoCsvImporter.new(csv_path: FIXTURE, admin_password: PASSWORD,
                         org_slug: "unyo-test", admin_email: "admin@unyo.test").call
  end

  test "rebuilds the account, org membership and a published Verto" do
    survey = import!

    org = Organisation.find_by!(slug: "unyo-test")
    assert_equal survey.organisation, org
    admin = User.find_by!(email_address: "admin@unyo.test")
    assert admin.authenticate(PASSWORD), "admin should log in with IMPORT_PASSWORD"
    assert_equal "admin", org.memberships.find_by(user: admin).role
    assert survey.published?, "imported Verto should be published"
    assert survey.show_results_comparison?
  end

  test "reconstructs the 25-card deck in order from the headers" do
    cards = import!.cards
    assert_equal 25, cards.size

    assert_equal "welcome_card", cards[0]["type"]
    # the 8-statement matrix expands to eight consecutive range cards
    assert(cards[4..11].all? { |c| c["type"] == "range" })
    assert_equal "Playing sport or being active helps me… feel like I belong", cards[6]["text"]
    # decision card-sorts become tap_cards
    assert_equal "tap_card", cards[14]["type"]
    assert_equal VertoCsvImporter::SKILLS, cards[14]["options"]
    assert_equal "tap_card", cards[18]["type"]
    # demographic tail, in order, correctly flagged
    assert_equal "month", cards[22]["input"]
    assert_equal "location", cards[23]["input"]
    assert cards[23]["demographic"]
    assert_equal VertoCsvImporter::GENDER_OPTS, cards[24]["options"]
  end

  test "maps a fully-completed respondent row into faithful answer values" do
    import!
    r = Response.find_by!(session_token: "unyo-test-QGAXXBSWS0o")

    assert_equal "completed", r.status
    assert_equal({ "type" => "range", "value" => 4 }, r.answers["1"])          # "2+ hours a week"
    assert_equal [ "Informal play with friends", "Gym or exercise" ], r.answers["2"]["value"]
    assert_equal "Feeling healthy or strong", r.answers["3"]["value"]
    assert_equal 1, r.answers["4"]["value"]   # matrix "2" -> index 1
    assert_equal 0, r.answers["5"]["value"]   # matrix "1" -> index 0
    assert_equal({ "type" => "rating", "value" => 5 }, r.answers["13"])         # "Very important"
    assert_equal "yes", r.answers["14"]["value"]["Speaking up"]                 # decision Yes pile
    assert_equal "School or work pressure", r.answers["17"]["value"]
    assert_equal "2026-06", r.answers["22"]["value"]                            # born date -> YYYY-MM
    assert_equal "GB|United Kingdom", r.answers["23"]["value"]                  # "England" resolved
    assert_equal "Male", r.answers["24"]["value"]
    # region derived from the resolved location, like the live player does
    assert_equal "GB", r.region_country
    assert_equal "United Kingdom", r.region_label
  end

  test "select_many splits the pipe-delimited cell into canonical labels" do
    import!
    r = Response.find_by!(session_token: "unyo-test-QGAXXBSWS0o")
    assert_equal({ "Speaking up" => "yes", "Leadership" => "yes", "Teamwork" => "yes",
                   "Problem-solving" => "yes", "Focus" => "yes", "Confidence" => "yes",
                   "Handling stress" => "yes", "Social Connections" => "yes" },
                 r.answers["14"]["value"])
  end

  test "a free-text Other pickOne answer is stored as the Other text, not a value" do
    import!
    r = Response.find_by!(session_token: "unyo-test-QF-79pwxOkE")
    entry = r.answers["17"]
    assert_equal "XYZ", entry["other"]
    assert_nil entry["value"]
  end

  test "an incomplete respondent is marked started with only the answered cards" do
    import!
    r = Response.find_by!(session_token: "unyo-test-QF-sTmCosjU")
    assert_equal "started", r.status
    assert r.answers.key?("1"), "physical-activity card was answered"
    assert_not r.answers.key?("24"), "never reached the gender card"
  end

  test "every stored answer is well-formed against its card" do
    survey = import!
    cards  = survey.cards
    survey.responses.find_each do |resp|
      resp.answers.each do |key, entry|
        card = cards[key.to_i]
        case card["type"]
        when "range"
          assert_includes 0..(card["options"].size - 1), entry["value"]
        when "rating"
          assert_includes 1..5, entry["value"]
        when "select_many"
          assert_empty entry["value"] - card["options"]
        when "multiple_choice"
          assert(entry["value"].nil? || card["options"].include?(entry["value"]))
        when "tap_card"
          assert_empty entry["value"].keys - card["options"]
          assert_empty entry["value"].values - %w[yes no unsure]
        end
      end
    end
  end

  test "re-running the import is idempotent" do
    first = import!
    count = first.responses.count
    second = import!
    assert_equal 1, Organisation.where(slug: "unyo-test").count
    assert_equal count, second.responses.count
  end

  test "apostrophe variants resolve to the canonical option (exports mix ’ and ')" do
    imp   = VertoCsvImporter.new(csv_path: FIXTURE, admin_password: PASSWORD)
    curly = VertoCsvImporter::HOPEFUL.index { |o| o.include?("take part in sport") }

    # A scale value with a straight apostrophe still maps to its index — without
    # this the answer would be silently dropped rather than counted.
    assert_equal curly, imp.send(:indexer, VertoCsvImporter::HOPEFUL).call("No, I don't take part in sport")
    # A choice value is normalised back to the card's exact label, so results
    # don't split one answer across two look-alike buckets.
    assert_equal "I don’t regularly take part",
                 imp.send(:canonical, "I don't regularly take part", VertoCsvImporter::SPORT_TYPES)
  end

  test "append adds new responses and refreshes existing ones in the same account" do
    survey    = import! # 5 responses
    survey_id = survey.id
    token     = survey.publish_token
    org_id    = survey.organisation_id
    assert_equal 5, survey.responses.count

    result = VertoCsvImporter.new(csv_path: APPEND_FIXTURE, org_slug: "unyo-test",
                                  admin_email: "admin@unyo.test", verto_slug: survey.slug).append!

    assert_equal survey_id, result[:survey].id, "the same Verto is reused, not rebuilt"
    assert_equal token, result[:survey].publish_token, "the /play link is preserved"
    assert_equal org_id, result[:survey].organisation_id, "the account is preserved"
    assert_equal 1, result[:added]
    assert_equal 5, result[:updated]
    assert_equal 6, result[:survey].responses.count
    assert_equal 1, Organisation.where(slug: "unyo-test").count, "no duplicate org created"
  end

  test "append refuses when there is no account to append to yet" do
    err = assert_raises(ArgumentError) do
      VertoCsvImporter.new(csv_path: APPEND_FIXTURE, org_slug: "does-not-exist").append!
    end
    assert_match(/run the full import first/, err.message)
  end

  # ── multilingual matching ──────────────────────────────────────────────────
  # A multilingual source survey exports each row's answers in the language the
  # respondent took it in. Exact-English matching dropped every one of those
  # answers silently — the importer now matches through the locale files'
  # translations, ordinal positions, and a per-import sidecar, and it REPORTS
  # anything that still matched nothing.

  def importer(**opts)
    VertoCsvImporter.new(csv_path: FIXTURE, admin_password: PASSWORD, **opts)
  end

  test "an agree-scale answer matches in every language the platform speaks" do
    imp    = importer
    lookup = imp.send(:indexer, VertoCsvImporter::AGREE)

    %i[fr de es ja ar].each do |loc|
      labels = I18n.t("defaults.range", locale: loc)
      assert_equal 3, lookup.call(labels[3]),
                   "#{loc}'s 'Agree' label should resolve to stop 3, got nil — " \
                   "that answer would have been silently dropped"
    end
  end

  test "a gender answer matches in the respondent's language and stores the canonical option" do
    imp = importer
    es_female = I18n.t("demographics.cards", locale: :es).last[:options][1]
    assert_equal "Female", imp.send(:canonical, es_female, VertoCsvImporter::GENDER_OPTS)
  end

  test "ordinal scale values match positionally, but only in range and only as prefixes" do
    imp    = importer
    lookup = imp.send(:indexer, VertoCsvImporter::AGREE)

    assert_equal 3, lookup.call("4")
    assert_equal 3, lookup.call("4 - Agree")
    assert_equal 3, lookup.call("4 – D'accord")
    assert_nil lookup.call("9"), "out-of-range ordinals must not clamp"

    # Labels that merely contain digits must never be read as ordinals.
    phys = imp.send(:indexer, VertoCsvImporter::PHYS_ACTIVITY)
    assert_equal 4, phys.call("2+ hours a week"), "the label itself must win"
    assert_nil phys.call("30 minutes"), "a bare number inside a phrase is not a position"
  end

  test "a sidecar translations file maps survey-specific labels the locale files can't know" do
    dir = Dir.mktmpdir
    path = File.join(dir, "map.translations.yml")
    File.write(path, { "fr" => { "Jeu informel entre amis" => "Informal play with friends" },
                       "Sala o ejercicio" => "Gym or exercise" }.to_yaml)

    imp = importer(translations: path)
    assert_equal "Informal play with friends",
                 imp.send(:canonical, "Jeu informel entre amis", VertoCsvImporter::SPORT_TYPES)
    assert_equal "Gym or exercise",
                 imp.send(:canonical, "Sala o ejercicio", VertoCsvImporter::SPORT_TYPES)
  ensure
    FileUtils.remove_entry(dir)
  end

  test "a value matching nothing in any language is reported, not silently lost" do
    imp  = importer
    spec = imp.send(:range_spec, "t", VertoCsvImporter::AGREE, "col")

    assert_nil spec[:get].call({ "col" => "Boaty McBoatface" }, "col")
    assert_equal({ "col" => { "Boaty McBoatface" => 1 } }, imp.unmatched)

    # Blanks are not noise — an unanswered cell is not an unmatched value.
    spec[:get].call({ "col" => "  " }, "col")
    assert_equal 1, imp.unmatched["col"].values.sum
  end

  test "a clean English import reports nothing unmatched" do
    imp = VertoCsvImporter.new(csv_path: FIXTURE, admin_password: PASSWORD,
                               org_slug: "unyo-test", admin_email: "admin@unyo.test")
    survey = imp.call
    assert_equal({}, imp.unmatched.reject { |_c, v| v.empty? },
                 "the all-English fixture matched everything before; a regression here " \
                 "means the new matching broke the exact-match path")
    assert_match(/none/, imp.summary_for(survey)[:unmatched])
  end

  test "an Other free-text row is recognised by its bracketed shape, not the English prefix" do
    imp = importer
    entry = imp.send(:difficult_value, "Autre (précisez) [le coût du transport]")
    assert_nil entry["value"]
    assert_equal "le coût du transport", entry["other"]
  end
end
