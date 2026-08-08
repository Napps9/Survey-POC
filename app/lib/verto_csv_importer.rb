# Rebuilds a Verto from a response-level CSV export of another survey platform
# (respondents are rows; the survey's questions are encoded in the column
# headers, each tagged with its source answer type, e.g. "(range)", "(pickMany)",
# "(matrix)", "(decision - Yes)"). It reconstructs a Playverto deck from those
# headers, creates an organisation + admin user to own it, and replays every
# row as a Response with a faithfully-mapped `answers` hash.
#
# The source answer types have no exact Playverto twin, so they are mapped to
# the closest native card that preserves the data:
#   range / pickOne / pickMany  -> range / multiple_choice / select_many
#   matrix (N statements, 1-5)  -> N range cards, one per statement
#   decision (Yes/No card-sort) -> tap_card (yes / no / unsure per option)
#   netPromoter (word scale)    -> range (the export used word labels, not 0-10)
#   rating (word scale)         -> rating (words mapped to a 1-5 star count)
#   age / location / gender     -> the standard demographic tail cards
#
# Idempotent: re-running destroys and rebuilds only the target org's own data,
# so it always converges on the same account, Verto, and response set.
#
# Usage (see lib/tasks/verto_import.rake):
#   IMPORT_PASSWORD='a-strong-passphrase' \
#     bin/rails "verto:import_csv[db/seeds/unyo_sport_x_changemaking_2026.csv]"
class VertoCsvImporter
  require "csv"
  require "zlib"

  DEFAULT_ORG_NAME    = "UNYO".freeze
  DEFAULT_ORG_SLUG    = "unyo".freeze
  DEFAULT_ADMIN_EMAIL = "admin@unyo.example".freeze
  DEFAULT_TITLE       = "UNYO Sport x Changemaking 2026".freeze
  DEFAULT_VERTO_SLUG  = "unyo-sport-changemaking".freeze
  BRAND_PALETTE       = { "primary" => "#00C2A8", "cta" => "#FF5A5F", "bg" => "#0F1B2D" }.freeze

  # ── answer-scale option orders (index order == stored range/rating value) ──
  # English is the canonical form answers are STORED as (the deck is built in
  # English), but matching is multilingual — see translation_aliases: a row
  # whose respondent took the survey in French carries French labels, and
  # dropping them because they aren't the English string is silent data loss.
  AGREE = [ "Strongly disagree", "Disagree", "Neutral", "Agree", "Strongly agree" ].freeze

  # Ages outside this range are still STORED — the respondent gave them — but
  # are not turned into a birth year, because banding a child cohort with an
  # imaginary 99-year-old is an arithmetic claim about people who don't exist.
  PLAUSIBLE_AGES = (4..25).freeze

  MATRIX_STATEMENTS = [
    "connect with people different from me",
    "feel more confident in myself",
    "feel like I belong",
    "deal with challenges in life",
    "stay calm when things get hard",
    "care more about the planet",
    "feel connected to nature",
    "believe I can make a difference"
  ].freeze

  SPORT_TYPES = [
    "Gym or exercise", "Informal play with friends", "Dance or movement",
    "Physical education (PE) or school sport", "Community sport club",
    "Online/virtual fitness", "I don’t regularly take part"
  ].freeze

  HELP_OPTIONS = [
    "Free or low-cost activities", "Better places to play", "Feeling welcome",
    "Fun social activities", "More choice in activities", "Supportive coaches"
  ].freeze

  SKILLS = [
    "Speaking up", "Leadership", "Teamwork", "Problem-solving",
    "Focus", "Confidence", "Handling stress", "Social Connections"
  ].freeze

  ADULTS = [
    "make me feel comfortable asking them for help", "help create safe environments",
    "positively influence my experience", "make me feel included",
    "help me feel more confident"
  ].freeze

  PHYS_ACTIVITY = [
    "I’m not active at the moment", "Less than 30 minutes a week",
    "About 30–60 minutes a week", "About 1–2 hours a week", "2+ hours a week"
  ].freeze
  HOPEFUL    = [ "No, I don’t take part in sport", "Not at all", "Very little", "Sometimes", "Yes, a lot" ].freeze
  IMPORTANCE = [ "Not important at all", "Not very important", "Neutral", "Quite important", "Very important" ].freeze
  BOUNCE     = [ "Not confident at all", "Slightly confident", "Somewhat confident", "Confident", "Very confident" ].freeze
  ACCESS     = [ "No access", "Very difficult", "Difficult", "Quite easy", "Very easy" ].freeze
  VOICE      = [ "Never", "Rarely", "Sometimes", "Often", "Always" ].freeze

  ENJOY_OPTS = [
    "Spending time with friends", "Feeling healthy or strong", "Feeling confident",
    "Having fun", "Relaxing or reducing stress", "Learning new skills",
    "Being part of a team", "Competing"
  ].freeze
  DIFFICULT_OPTS = [ "Cost", "School or work pressure", "Lack of time", "Not interested in sport" ].freeze
  WORLDCUP_OPTS  = [ "Yes, a lot", "A little", "Not really", "Not sure", "Not at all" ].freeze
  GENDER_OPTS    = [ "Male", "Female", "Non-binary", "Other", "Prefer not to say" ].freeze

  # Country-name aliases the WorldRegions display-name table doesn't cover
  # (formal/alternate spellings and UK constituent nations seen in the export).
  COUNTRY_ALIASES = {
    "england" => "GB", "scotland" => "GB", "wales" => "GB", "northern ireland" => "GB",
    "united states of america" => "US", "usa" => "US", "u.s.a." => "US", "u.s." => "US",
    "uk" => "GB", "great britain" => "GB",
    "congo, democratic republic of the" => "CD", "democratic republic of the congo" => "CD",
    "dr congo" => "CD", "congo (kinshasa)" => "CD", "congo, the democratic republic of the" => "CD",
    "palestine, state of" => "PS", "palestinian territory" => "PS", "palestinian territories" => "PS",
    "korea, republic of" => "KR", "south korea" => "KR", "republic of korea" => "KR", "korea, south" => "KR",
    "korea, democratic people's republic of" => "KP", "north korea" => "KP",
    "tanzania, united republic of" => "TZ", "tanzania" => "TZ",
    "russian federation" => "RU", "russia" => "RU",
    "iran, islamic republic of" => "IR", "iran" => "IR",
    "viet nam" => "VN", "vietnam" => "VN",
    "syrian arab republic" => "SY", "syria" => "SY",
    "bolivia, plurinational state of" => "BO", "bolivia" => "BO",
    "venezuela, bolivarian republic of" => "VE", "venezuela" => "VE",
    "moldova, republic of" => "MD", "moldova" => "MD",
    "türkiye" => "TR", "turkiye" => "TR", "turkey" => "TR",
    "côte d'ivoire" => "CI", "cote d'ivoire" => "CI", "ivory coast" => "CI",
    "lao people's democratic republic" => "LA", "laos" => "LA",
    "brunei darussalam" => "BN", "brunei" => "BN",
    "cabo verde" => "CV", "cape verde" => "CV",
    "myanmar" => "MM", "burma" => "MM",
    "eswatini" => "SZ", "swaziland" => "SZ",
    "macedonia, the former yugoslav republic of" => "MK", "north macedonia" => "MK",
    "czech republic" => "CZ", "czechia" => "CZ",
    "hong kong" => "HK", "taiwan, province of china" => "TW", "taiwan" => "TW",
    "the netherlands" => "NL", "netherlands" => "NL",
    "the gambia" => "GM", "gambia" => "GM", "south african" => "ZA"
  }.freeze

  # `deck` names which source survey this export is (see VertoDecks). It
  # defaults to the UNYouth deck this class was originally written for, so every
  # existing caller behaves exactly as it did; explicit org/title/slug kwargs
  # still win over the deck's own, which is what the rake task's ENV overrides
  # and the tests rely on.
  def initialize(csv_path:, admin_password: nil, deck: nil,
                 org_name: nil, org_slug: nil,
                 admin_email: nil, admin_name: nil,
                 title: nil, verto_slug: nil,
                 translations: nil)
    @deck           = VertoDecks.fetch(deck || VertoDecks::DEFAULT)
    @csv_path       = csv_path
    @admin_password = admin_password
    @org_name       = org_name    || @deck.org_name
    @org_slug       = org_slug    || @deck.org_slug
    @admin_email    = admin_email || @deck.admin_email
    @admin_name     = admin_name  || "#{@org_name} Admin"
    @title          = title       || @deck.title
    @verto_slug     = verto_slug  || @deck.verto_slug
    @name_to_code   = WorldRegions::COUNTRIES.map { |code, c| [ c[:name].downcase, code ] }.to_h
    # Optional sidecar mapping translated answer labels → the canonical English
    # option, for survey-specific lists our locale files can't know about.
    # Defaults to "<csv>.translations.yml" next to the export when it exists.
    @translations_path = translations || default_translations_path
    @unmatched = Hash.new { |h, k| h[k] = Hash.new(0) }
    @dropped   = Hash.new { |h, k| h[k] = Hash.new(0) }
    @rows_without_id = 0
  end

  # { column header => { raw value => count } } of answer values that matched
  # no option in ANY language — i.e. what the import dropped (scales) or passed
  # through as its own bucket (choices). Empty after a clean import; anything
  # here is the first place to look when counts seem low.
  attr_reader :unmatched

  # { "column" => { "value (reason)" => count } } of source values the import
  # deliberately did NOT store as answers: a "Skipped" cell, the second value
  # of a cell that held two, an age too implausible to band, a country code the
  # name overruled, a date that would not parse.
  #
  # #unmatched is "the deck did not recognise this"; #dropped is "the deck
  # recognised it and chose not to keep it there". Both are printed after an
  # import, because a transformation nobody can see is indistinguishable from a
  # mistake.
  attr_reader :dropped

  # Rows the export contained that carry no Viewing ID and so cannot become a
  # response at all.
  attr_reader :rows_without_id

  # Where this import lands, after the deck's own identity and any explicit
  # override have been resolved — so a caller (the rake tasks) can find the
  # account it just built without repeating that resolution.
  attr_reader :org_slug, :verto_slug

  # Builds the account + Verto + responses in one transaction. Returns the Survey.
  def call
    require_password!
    plan!
    specs = build_specs
    cards = specs.map { |s| s[:card] }

    survey = nil
    ActiveRecord::Base.transaction do
      destroy_existing!
      org = create_organisation!
      create_admin!(org)
      survey = create_survey!(org, cards)

      batch = []
      each_row do |row|
        attrs = response_attributes(specs, row)
        next unless attrs

        batch << attrs.merge(survey_id: survey.id)
        batch = flush!(batch) if batch.size >= INSERT_BATCH
      end
      flush!(batch, force: true)
    end
    survey.reload
  end

  # Rows go in a batch at a time rather than one Response at a time, because the
  # largest export here is 126,895 of them and per-row validation, callbacks and
  # broadcasts are most of that cost.
  #
  # `answered` is normally kept in step by a before_save, so it is computed here
  # instead — it is the flag the corpus counts on, and an insert that skipped it
  # would leave a whole import invisible to Ask Verto.
  INSERT_BATCH = 1_000

  def flush!(batch, force: false)
    return batch if batch.empty? || (!force && batch.size < INSERT_BATCH)

    Response.insert_all!(batch)
    []
  end

  # Upsert the CSV into an EXISTING account + Verto instead of rebuilding: adds
  # responses that are new to this export and refreshes ones already imported,
  # keyed on the deterministic "<slug>-<Viewing ID>" token. The org, admin,
  # Verto (and its /play link) and any organically-collected responses (which
  # carry random tokens) are left untouched. Returns { survey:, added:, updated: }.
  def append!
    plan!
    specs = build_specs
    cards = specs.map { |s| s[:card] }

    org = Organisation.find_by(slug: @org_slug)
    raise ArgumentError, "No organisation '#{@org_slug}' to append to — run the full import first." unless org

    survey = org.surveys.kept.find_by(slug: @verto_slug) || org.surveys.kept.order(:id).first
    raise ArgumentError, "No Verto found in '#{@org_slug}' to append to." unless survey

    # Answer keys are positional indices into the deck, so appending is only
    # safe when the live Verto's questions still match the CSV's reconstructed
    # deck — otherwise a full re-import is the right tool.
    unless survey.cards == cards
      raise ArgumentError, "The Verto's questions differ from the CSV's reconstructed deck — " \
                           "appending would misalign answers. Re-run the full import instead."
    end

    added = 0
    updated = 0
    ActiveRecord::Base.transaction do
      each_row do |row|
        attrs = response_attributes(specs, row)
        next unless attrs

        existing = survey.responses.find_by(session_token: attrs[:session_token])
        if existing
          existing.update!(attrs.except(:session_token, :created_at, :updated_at))
          updated += 1
        else
          survey.responses.create!(attrs)
          added += 1
        end
      end
    end
    { survey: survey, added: added, updated: updated }
  end

  # Builds the account and the Verto from the deck alone, with no export to
  # replay. Returns the Survey.
  #
  # Idempotent per VERTO, not per account — unlike `call`, which owns its whole
  # organisation. Sibling decks share one account (the Happiness Project's child
  # and adult flows are both Walls), so rebuilding one must not take the other
  # down with it. Only the Verto this deck names is replaced.
  def build!
    require_password!
    cards = build_specs.map { |spec| spec[:card] }

    survey = nil
    ActiveRecord::Base.transaction do
      org = Organisation.find_by(slug: @org_slug) || create_organisation!
      create_admin!(org) unless User.exists?(email_address: @admin_email)
      org.surveys.where(slug: @verto_slug).find_each(&:destroy!)
      survey = create_survey!(org, cards)
    end
    survey
  end

  # Removes the org this importer owns and its admin user (and, by dependent
  # destroy, the Verto and every response) — so `call` is safe to re-run.
  def destroy!
    ActiveRecord::Base.transaction { destroy_existing! }
  end

  def summary_for(survey)
    tagged = survey.responses.where.not(region_country: nil)
    {
      org:        "#{@org_name} (#{@org_slug})",
      login:      @admin_email,
      title:      survey.title,
      play_link:  "/play/#{survey.slug || survey.publish_token}",
      cards:      survey.cards.size,
      responses:  survey.responses.count,
      completed:  survey.responses.where(status: "completed").count,
      answered:   survey.responders_count,
      regions:    "#{tagged.count} tagged across #{tagged.distinct.count(:region_country)} countries",
      unmatched:  (@unmatched.empty? ? "none — every answer matched an option" :
                     "#{@unmatched.values.sum { |h| h.values.sum }} values across #{@unmatched.size} columns (see #unmatched)"),
      dropped:    (@dropped.empty? ? "none — nothing was deliberately left out" :
                     "#{@dropped.values.sum { |h| h.values.sum }} values across #{@dropped.size} columns (see #dropped)"),
      no_id:      (@rows_without_id.zero? ? "none" : "#{@rows_without_id} rows had no Viewing ID and could not be replayed")
    }
  end

  private

  def require_password!
    return if @admin_password.to_s.length >= 12

    raise ArgumentError, "admin_password must be at least 12 characters " \
                         "(set IMPORT_PASSWORD in the environment)."
  end

  def destroy_existing!
    Organisation.where(slug: @org_slug).find_each(&:destroy!)
    User.where(email_address: @admin_email).find_each(&:destroy!)
  end

  def create_organisation!
    Organisation.create!(name: @org_name, slug: @org_slug, default_brand_palette: @deck.brand_palette)
  end

  def create_admin!(org)
    user = User.create!(name: @admin_name, email_address: @admin_email, password: @admin_password)
    Membership.create!(user: user, organisation: org, role: "admin")
    user
  end

  def create_survey!(org, cards)
    survey = Survey.create!(
      **@deck.survey_attributes,
      organisation: org, title: @title,
      default_locale: "en", locales: [ "en" ], cards: cards,
      slug: (Survey.slug_taken?(@verto_slug) ? nil : @verto_slug),
      brand_palette: @deck.brand_palette
    )
    survey.update!(publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
    survey
  end

  # The export's rows, with the header put back over the right columns.
  #
  # Some exports carry one more DATA column than their header names, which makes
  # every `row["…"]` lookup below resolve to its neighbour — a clean-looking
  # import of comprehensively wrong answers. VertoExportLayout detects that from
  # the shape of the data and either corrects it or refuses the file. Aligned
  # exports pass through untouched.
  def plan!
    ExportManifest.verify!(@csv_path)
    @plan = VertoExportLayout.plan_from { open_export }
    @layout_shift = @plan.shift
    @headers = @plan.headers
    @plan
  end

  # Every data row, as a CSV::Row over the CORRECTED header.
  #
  # Streamed rather than materialised: the largest export here is 127 MB
  # decompressed, and `CSV.read` on it would build the whole table in Ruby
  # objects before a single response was written. The layout decision is made
  # first, from the header plus a bounded sample, so this pass only has to
  # attach a header it already knows.
  # Public because reading the export is not only the import's business: the
  # reconciliation task recomputes every distribution straight from these rows
  # and compares it to what was stored, which is the whole proof that the
  # import changed nothing.
  public def each_row
    return enum_for(:each_row) unless block_given?

    plan! if @plan.nil?
    io = open_export
    first = true
    CSV.new(io).each do |fields|
      if first
        first = false
        next
      end
      yield CSV::Row.new(@plan.headers, fields)
    end
  ensure
    io&.close
  end

  # Exports are committed gzipped — the Big Green file is 127.7 MB as CSV and
  # GitHub rejects anything over 100 MB — so the importer reads either form.
  # Nothing else in the path knows the difference.
  def open_export
    if @csv_path.to_s.end_with?(".gz")
      Zlib::GzipReader.new(File.open(@csv_path, "rb"), external_encoding: "UTF-8")
    else
      File.open(@csv_path, "r:bom|utf-8")
    end
  end

  # Response attributes for one CSV row (nil when the row has no Viewing ID).
  # Shared by the full import (create) and append (upsert) so both derive the
  # same session token, answers, region, status and timestamp from a row.
  def response_attributes(specs, row)
    token = row["Viewing ID"].to_s.strip
    if token.empty?
      # Counted, because "the file had 3,477 rows and the Verto has 3,470" is a
      # question somebody will ask, and "some rows had no id" has to be an
      # answer the import can give.
      @rows_without_id += 1
      return nil
    end

    answers = {}
    demo    = {}
    genders = {}
    specs.each_with_index do |spec, idx|
      source = spec[:col] || spec[:cols]
      next unless source

      entry = spec[:get].call(row, source)
      next unless entry

      answers[idx.to_s] = entry
      next unless spec[:demo]

      demo[spec[:demo]] = entry["value"]
      genders[spec[:demo]] = Array(spec[:card]["options"]) if spec[:demo] == :gender
    end

    country, label = region_from(demo[:region])
    created = parse_created_at(row["Start date"], row["Start time"])
    if created.nil?
      record_dropped("Start date", "#{row['Start date']} #{row['Start time']}".strip,
                     "unparseable — stamped with the import time instead")
      created = Time.current
    end

    {
      # Two exports of the SAME programme are two collection channels, and a
      # Viewing ID is only unique within one file. Without the mode in the key
      # the paper cohort would upsert over the digital one and both would be
      # wrong, silently.
      session_token:  [ @org_slug, @deck.collection_mode, token ].compact.join("-"),
      # Normally kept in step by Response#sync_answered. Rows go in through
      # insert_all! for speed, which skips callbacks — and this is the flag the
      # whole corpus counts on, so an import that left it false would be a
      # Verto that imported perfectly and was invisible to Ask Verto.
      answered:       answers.values.any? { |a| Response.answered_entry?(a) },
      # A fact about the session, not a gate. Nothing in the corpus path reads
      # it — a respondent who answered eleven of twenty-four questions answered
      # those eleven, and each question counts the people who answered it.
      status:         (row["Completion percentage"].to_f >= 100.0 ? "completed" : "started"),
      answers:        answers,
      region_country: country, region_label: label,
      locale:         row["Language"].to_s.strip.presence || "en",
      # Only set when the deck says this export was collected some way other
      # than through the player — it is what keeps a paper cohort comparable
      # after two exports are merged into one Verto.
      collection_mode: @deck.collection_mode,
      # The segment dimensions Ask Verto publishes read these columns, not the
      # answers hash — PlayerController fills them in for a live respondent, so
      # an imported one has to be given them too or the Verto contributes no
      # gender or age breakdown at all.
      #
      # Only a value the card actually offers becomes a segment label, matching
      # PlayerController's own guard: an unmatched free-text gender is a real
      # answer and is stored as one, but it must not become a published cohort.
      demographic_gender:     segment_gender(demo[:gender], genders[:gender]),
      demographic_birth_year: birth_year_from(demo, created),
      created_at:     created, updated_at: created
    }
  end

  def segment_gender(value, options)
    v = value.to_s.presence
    v if v && Array(options).map(&:to_s).include?(v)
  end

  # The birth year the segment aggregator bands on. Two shapes reach it: an age
  # in years (age_spec) and a "YYYY-MM" birth month (born_spec) — before this,
  # only the first was wired up, so every UNYouth respondent had a birth month
  # in their answers and no age segment anywhere.
  #
  # An age is subtracted from the ROW's own year, not today's, so an export
  # replayed years later does not age its respondents.
  def birth_year_from(demo, created)
    year =
      if (born = demo[:born].to_s[/\A(\d{4})/, 1])
        born.to_i
      elsif (years = demo[:age].to_s[/\A\d{1,3}\z/]&.to_i)
        # PLAUSIBLE_AGES governs banding only. The age itself is already stored
        # exactly as the respondent gave it.
        return nil unless PLAUSIBLE_AGES.cover?(years)

        created.year - years
      end
    year if year&.between?(1900, Date.current.year)
  end

  # ── the deck API ──────────────────────────────────────────────────────────
  # Everything below here is what a VertoDecks deck calls to describe itself.
  # It is public because decks are separate objects now: a deck's `specs` method
  # is handed this importer and builds its cards out of these.
  public

  # The first of `names` this export actually has a column for, nil if none.
  #
  # Two exports of one programme word the same question's header differently
  # ("Where do you live? Type and choose…" on paper, "…Type your country &amp;
  # choose…" digitally). A deck lists both spellings and gets whichever is
  # here, so one deck covers both files.
  def column(*names)
    names.flatten.compact.find { |name| headers.include?(name) }
  end

  def headers = @headers ||= []

  # A cell's answer atoms: separator-split, entity-decoded, de-duplicated, with
  # the deck's non-answers ("Skipped") removed.
  #
  # Splitting on the bare "|||" and stripping afterwards is deliberate — the
  # exports pad the separator with anything from no spaces to 44 of them, and
  # splitting on " ||| " leaves that padding on a third of the atoms, turning
  # every affected option into its own unmatched bucket.
  #
  # `col` is only used to say what was dropped. Pass it: an atom removed without
  # a column name is removed without a trace.
  def atoms(cell, col = nil)
    kept, dropped = split_atoms(cell).uniq.partition { |a| !non_answer?(a) }
    dropped.each { |a| record_dropped(col, a, "the deck calls this a non-answer") }
    kept
  end

  # The single value of a single-select cell. Some cells repeat their answer
  # ("Happy ||| Happy") — de-duplication has already dealt with those — and a
  # few hold two genuinely different ones ("Nervous ||| Tired", 242 of them in
  # the Big Green export). The first is the answer; the rest are reported,
  # because a discarded answer that nobody counts is a changed dataset.
  def single_atom(cell, col = nil)
    chosen, *rest = atoms(cell, col)
    rest.each { |a| record_dropped(col, a, "a second answer in a single-answer cell") }
    chosen
  end

  # A card with no column behind it, for a deck we have the QUESTIONS for but
  # not (yet) the answers. It builds a real, playable Verto; it contributes
  # nothing to Ask Verto until somebody actually answers it, which is the
  # honest state of a survey that hasn't been fielded.
  def card_spec(card) = { card: card, get: ->(_row, _source) { nil } }

  # ── card deck + per-row extractors ────────────────────────────────────────
  # Each spec: { card:, col:/cols:, get: ->(row, source) => answer-entry|nil }.
  # Order here == card order == the positional string keys in `answers`.
  # An optional `demo:` (:gender or :age) also feeds the response's demographic
  # column, which is what Ask Verto segments on.
  def build_specs
    @deck.specs(self)
  end

  def unyo_specs
    specs = []
    specs << welcome_spec

    specs << range_spec("In a typical week, how physically active are you?", PHYS_ACTIVITY,
      "In a typical week, how physically active are you? (range)")

    specs << pick_many_spec("Which types of sport do you take part in most often?", SPORT_TYPES,
      "Which types of sport do you take part in most often? (pickMany)")

    specs << pick_one_spec("What do you enjoy most about sport?", ENJOY_OPTS,
      "What do you enjoy most about sport? (pickOne)")

    MATRIX_STATEMENTS.each do |statement|
      specs << matrix_spec(statement)
    end

    specs << range_spec("Does sport influence how hopeful you feel about your life?", HOPEFUL,
      "Does sport influence how hopeful you feel about your life? (range)")

    specs << rating_spec("How important is sport to supporting your mental well-being?", IMPORTANCE,
      "How important is sport to supporting your mental well-being? (rating)")

    specs << decision_spec("Which skills are you developing through sport?", SKILLS,
      yes: "Which skills are you developing through sport? (decision - Yes)",
      no:  "Which skills are you developing through sport? (decision - No)")

    specs << range_spec("When things go wrong, how confident are you that you can bounce back?", BOUNCE,
      "When things go wrong in your life, how confident are you that you can bounce back? (netPromoter)")

    specs << range_spec("How easy is it for you to access sport where you live?", ACCESS,
      "How easy is it for you to access sport where you live? (range)")

    specs << difficult_spec

    specs << decision_spec("Adults involved in sport…", ADULTS,
      yes: "Adults involved in sport... (decision - Yes)",
      no:  "Adults involved in sport... (decision - No)")

    specs << pick_one_spec("Do events like the World Cup make you feel more connected to your community?", WORLDCUP_OPTS,
      "Do events like the World Cup make you feel more connected to your local community? (pickOne)")

    specs << pick_many_spec("What would help more young people take part in sport where you live?", HELP_OPTIONS,
      "What would help more young people take part in sport where you live? (pickMany)")

    specs << range_spec("Do you feel your voice is heard in decisions about sport in your community?", VOICE,
      "Do you feel your voice is heard when decisions are made about sport in your community? (range)")

    specs << born_spec
    specs << location_spec
    specs << gender_spec
    specs
  end

  def welcome_spec
    { card: { "type" => "welcome_card", "title" => @title,
              "text" => "Sport, wellbeing and changemaking — tell us how sport fits into your life. Anonymous, a few minutes." },
      get: ->(_row, _source) { nil } }
  end

  # A five-stop ordinal scale, and ONLY a five-stop one.
  #
  # A range card stores an INDEX, and Survey::RANGE_POINTS coerces every range
  # card to exactly five options when it is saved — so a 4-, 6- or 11-value
  # column modelled as a range has its labels resized underneath the indices
  # that point at them, with no symptom, because answers are positional. Any
  # other shape belongs on a pick_one_spec, where the stored value is the
  # source's own label.
  def range_spec(text, options, col)
    unless options.size == Survey::RANGE_POINTS
      raise ArgumentError, "range_spec needs exactly #{Survey::RANGE_POINTS} options " \
                           "(#{text.inspect} has #{options.size}). Use pick_one_spec: it stores " \
                           "the label, so the scale keeps its own shape."
    end

    lookup = indexer(options)
    { card: { "type" => "range", "text" => text, "options" => options }, col: col,
      get: ->(row, source) {
        v = single_atom(row[source], source)
        i = lookup.call(v)
        record_unmatched(source, v) if i.nil?
        range_entry(i)
      } }
  end

  # A ranking. The order of the atoms in the cell IS the answer — set-ifying or
  # sorting them produces a clean-looking import with the entire signal gone.
  def prioritise_spec(text, options, col)
    { card: { "type" => "prioritise", "text" => text, "options" => options }, col: col,
      get: ->(row, source) {
        ranked = atoms(row[source], source).map { |a| canonical(a, options) }
        ranked.each { |a| record_unmatched(source, a) unless options.include?(a) }
        kept = ranked.select { |a| options.include?(a) }
        kept.empty? ? nil : { "type" => "prioritise", "value" => kept }
      } }
  end

  # Free text, stored as the respondent wrote it — in their own language, and
  # with the export's HTML entities decoded so a quote reads as a quote.
  def open_text_spec(text, col)
    { card: { "type" => "open_ended", "text" => text }, col: col,
      get: ->(row, source) {
        v = unescape(row[source]).strip
        v.empty? ? nil : { "type" => "open_ended", "value" => v }
      } }
  end

  # An age in years (not the "YYYY-MM" birth month the UNYouth export carries).
  #
  # The age the respondent gave is stored WHATEVER it is — the exports have a
  # junk tail (99 appears 119 times in one) but 99 is what that row says, and
  # deciding it is implausible is an analysis judgement, not a licence to delete
  # the answer. `plausible` therefore governs only the derived birth year, which
  # is an index for banding rather than an answer.
  def age_spec(text, col, plausible: (4..25))
    { card: { "type" => "open_ended", "input" => "number", "text" => text, "demographic" => true },
      col: col, demo: :age,
      get: ->(row, source) {
        raw = single_atom(row[source], source)
        years = raw.to_s[/\A\d{1,3}\z/]&.to_i
        next record_unmatched(source, raw) unless years

        record_dropped(source, raw, "outside #{plausible} — kept as an answer, not banded") unless plausible.cover?(years)
        { "type" => "open_ended", "value" => years.to_s, "banded" => plausible.cover?(years) }
      } }
  end

  # A "<Country name> - <CC>" location column.
  #
  # The stored label is the export's OWN string, not the canonical country name.
  # Two respondents who wrote "England" and "United Kingdom" both resolve to GB
  # for mapping and segmenting, and both keep what they actually said.
  def country_spec(text, col)
    { card: { "type" => "open_ended", "input" => "location", "text" => text,
              "description" => "Used to build a map you can explore after finishing.",
              "demographic" => true },
      col: col, demo: :region,
      get: ->(row, source) {
        raw = single_atom(row[source], source)
        code = country_code_from(raw)
        next record_unmatched(source, raw) unless code

        # The export's own trailing token, where it had one and it disagreed —
        # "United Kingdom - EN", "Bangladesh - Comics". Resolving by name is
        # right, and silently is not.
        exported = raw.to_s[/-\s*([A-Za-z]{2})\s*\z/, 1]&.upcase
        record_dropped(source, raw, "exported code #{exported} resolved to #{code} by name") if exported && exported != code

        { "type" => "open_ended", "value" => "#{code}|#{raw}" }
      } }
  end

  # A card-sort with a named pile per answer, rather than the yes/no the
  # tap_card type is built around. Each statement becomes its own
  # multiple_choice so a citation reads "Not enough", which is what the
  # respondent actually said — mapping a three-point sufficiency scale onto
  # yes/no/unsure would publish a different question's answer.
  def pile_specs(text, statements, piles)
    statements.map do |statement|
      { card: { "type" => "multiple_choice", "text" => "#{text} #{statement}",
                "options" => piles.keys },
        cols: piles,
        get: ->(row, source) {
          label, = source.find { |_pile, col| atoms(row[col], col).any? { |a| canon(a) == canon(statement) } }
          label.nil? ? nil : { "type" => "multiple_choice", "value" => label }
        } }
    end
  end

  def matrix_spec(statement)
    col = "Playing sport or being active helps me… - #{statement} (matrix)"
    agree = indexer(AGREE)
    { card: { "type" => "range", "text" => "Playing sport or being active helps me… #{statement}", "options" => AGREE },
      col: col, get: ->(row, source) {
        # Labels first. matrix_index reads any digit run in the cell, so trying
        # it first would swallow every label that happens to contain a numeral.
        i = agree.call(row[source]) || matrix_index(row[source])
        record_unmatched(source, row[source]) if i.nil?
        range_entry(i)
      } }
  end

  def rating_spec(text, options, col)
    lookup = indexer(options)
    { card: { "type" => "rating", "text" => text, "options" => options }, col: col,
      get: ->(row, source) {
        i = lookup.call(row[source])
        record_unmatched(source, row[source]) if i.nil?
        i.nil? ? nil : { "type" => "rating", "value" => i + 1 }
      } }
  end

  def pick_one_spec(text, options, col, demographic: false, demo: nil)
    card = { "type" => "multiple_choice", "text" => text, "options" => options }
    card["demographic"] = true if demographic
    { card: card, col: col, demo: demo,
      get: ->(row, source) {
        v = single_atom(row[source], source)
        next nil if v.nil?
        cv = canonical(v, options)
        # Kept, not dropped. A multiple_choice stores a LABEL, so it can hold a
        # value the deck did not anticipate — and holding it is more honest than
        # deleting the only record that this respondent answered at all. Types
        # that store an index (range, rating) cannot do the same, which is why
        # they report and store nothing.
        record_unmatched(source, v) unless options.include?(cv)
        { "type" => "multiple_choice", "value" => cv }
      } }
  end

  def pick_many_spec(text, options, col)
    { card: { "type" => "select_many", "text" => text, "options" => options }, col: col,
      get: ->(row, source) {
        chosen = atoms(row[source], source).map { |a| canonical(a, options) }
        chosen.each { |a| record_unmatched(source, a) unless options.include?(a) }
        chosen.empty? ? nil : { "type" => "select_many", "value" => chosen }
      } }
  end

  def decision_spec(text, options, cols)
    { card: { "type" => "tap_card", "text" => text, "options" => options }, cols: cols,
      get: ->(row, source) { tap_value(row, source, options) } }
  end

  def difficult_spec
    { card: { "type" => "multiple_choice",
              "text" => "What makes it difficult for you to take part in sport regularly?",
              "options" => DIFFICULT_OPTS, "allow_other" => true },
      col: "What makes it difficult for you to take part in sport regularly? (pickOne)",
      get: ->(row, source) { difficult_value(row[source]) } }
  end

  def born_spec
    { card: { "type" => "open_ended", "input" => "month", "text" => "When were you born?", "demographic" => true },
      col: "When were you born? (age)", demo: :born,
      get: ->(row, source) { born_value(row[source]) } }
  end

  def location_spec
    { card: { "type" => "open_ended", "input" => "location", "text" => "What country do you live in?",
              "description" => "Powered by OpenStreetMap — helps build a map you can explore after finishing.",
              "demographic" => true },
      col: "What country do you live in? (location)", demo: :region,
      get: ->(row, source) {
        loc = resolve_location(row[source])
        loc.nil? ? nil : { "type" => "open_ended", "value" => loc }
      } }
  end

  def gender_spec
    { card: { "type" => "multiple_choice", "text" => "What gender do you identify as?",
              "options" => GENDER_OPTS, "demographic" => true },
      col: "What gender do you identify as? (gender)", demo: :gender,
      get: ->(row, source) {
        v = single_atom(row[source], source)
        next nil if v.nil?
        cv = canonical(v, GENDER_OPTS)
        next record_unmatched(source, v) unless GENDER_OPTS.include?(cv)
        { "type" => "multiple_choice", "value" => cv }
      } }
  end

  # ── value coercion helpers ────────────────────────────────────────────────
  private

  # Unify apostrophe variants, case and surrounding whitespace. The exports mix
  # curly (’) and straight (') apostrophes for the same label, and one export
  # writes "to understand the world and help make it better" in one column and
  # "To understand…" in another — so without this, 377 respondents' answers
  # become their own results bucket. Matching is on the canon; the label that
  # gets STORED is always the deck's own, so folding case here doesn't change
  # what a citation reads.
  def canon(text)
    text.to_s.strip.tr("’‘", "''").downcase
  end

  # The exports carry HTML entities in both values and header names
  # (&#39;, &quot;, &amp;) — a quote printed with them in is not the sentence
  # the respondent wrote.
  def unescape(text) = CGI.unescapeHTML(text.to_s)

  # Values that mean "no answer" rather than an answer. Deck-declared, because
  # "Skipped" is a real option label somewhere, just not in these decks.
  def non_answer?(value)
    @deck.non_answers.any? { |n| canon(n) == canon(value) }
  end

  # The country behind a "<Country name> - <CC>" cell. The NAME decides when
  # the two disagree: the trailing token is a real code often enough to be
  # worth trying, and wrong often enough ("United Kingdom - EN", "Spain - EN",
  # "Bangladesh - Comics") that trusting it would file thousands of respondents
  # under a country they don't live in.
  def country_code_from(raw)
    s = raw.to_s.strip
    return nil if s.empty?

    # rpartition anchors on the RIGHTMOST place the pattern can start, which is
    # the dash itself — the leading \s* matches nothing, so the country name
    # comes back with its trailing space still on it.
    name, sep, code = s.rpartition(/\s*-\s*/)
    name = (sep.empty? ? s : name).strip

    by_name = COUNTRY_ALIASES[name.downcase] || @name_to_code[name.downcase]
    return by_name if by_name

    code.to_s.strip.upcase.then { |c| WorldRegions.valid?(c) ? c : nil }
  end

  # ── multilingual matching ─────────────────────────────────────────────────
  # A multilingual source survey exports each row's answers in the language the
  # RESPONDENT took it in, so exact-English matching drops every non-English
  # answer. Matching therefore tries, in order: the exact English label, a
  # translated alias resolved back to English, and (for scales) the ordinal
  # position many platforms prefix or export bare ("4", "4 - D'accord").

  def default_translations_path
    p = "#{@csv_path.to_s.sub(/\.csv\z/i, '')}.translations.yml"
    File.exist?(p) ? p : nil
  end

  # canon(label in any language) => canonical English label. Built from the
  # scales our locale files already translate — the agree scale
  # (defaults.range) and the gender options (demographics.cards), positionally
  # per locale — plus the sidecar file for survey-specific option lists.
  def translation_aliases
    @translation_aliases ||= begin
      map = {}
      I18n.available_locales.each do |loc|
        Survey.localized_range_labels(loc).each_with_index do |label, i|
          map[canon(label)] ||= AGREE[i]
        end
        gender_card = Array(I18n.t("demographics.cards", locale: loc, default: nil)).last
        Array(gender_card.is_a?(Hash) ? gender_card[:options] : nil).each_with_index do |label, i|
          map[canon(label)] ||= GENDER_OPTS[i] if GENDER_OPTS[i]
        end
      end
      sidecar_translations.each { |from, to| map[canon(from)] = to.to_s }
      map
    end
  end

  # The sidecar is a YAML hash — flat ({ "étiquette" => "English label" }) or
  # nested per-locale ({ "fr" => { … } }); both flatten to the same aliases.
  def sidecar_translations
    return {} unless @translations_path

    data = YAML.load_file(@translations_path)
    return {} unless data.is_a?(Hash)

    data.flat_map { |k, v| v.is_a?(Hash) ? v.to_a : [ [ k, v ] ] }
        .select { |_k, v| v.is_a?(String) }.to_h
  end

  # The exact card-option label a raw value matches — in any language — so
  # stored answers line up with the (English) card options. Unknown values
  # pass through, as before.
  def canonical(value, options)
    c = canon(value)
    options.find { |o| canon(o) == c } ||
      options.find { |o| canon(o) == canon(translation_aliases[c].to_s) } ||
      value
  end

  # Maps an ordered options list to a ->(text) { index } lookup (nil if absent
  # in every language and not an in-range ordinal).
  def indexer(options)
    lut = options.each_with_index.to_h { |o, i| [ canon(o), i ] }
    ->(text) {
      c = canon(text)
      lut[c] || lut[canon(translation_aliases[c].to_s)] || ordinal_index(c, options.size)
    }
  end

  # "4" or "4 - Agree"/"4 – D'accord"/"4: …" → index 3, only when the number is
  # a plausible 1-based position on this scale. Never fires for labels that
  # merely contain digits ("2+ hours a week", "About 30–60 minutes a week").
  def ordinal_index(text, size)
    n = text[/\A(\d+)\s*(?:[-–:.]|\z)/, 1]&.to_i
    n&.between?(1, size) ? n - 1 : nil
  end

  # Every value that resolved to nothing, kept and surfaced (summary_for, the
  # rake output) instead of silently dropped — the failure mode a non-English
  # export used to hit for every row.
  def record_unmatched(col, value)
    v = value.to_s.strip
    @unmatched[col][v] += 1 unless v.empty?
    nil
  end

  # A value the deck understood and deliberately did not store. `reason` is
  # part of the key so one column can report several kinds of loss separately.
  def record_dropped(col, value, reason)
    v = value.to_s.strip
    @dropped[col.to_s][%(#{v} — #{reason})] += 1 unless v.empty?
    nil
  end

  def range_entry(index)
    index.nil? ? nil : { "type" => "range", "value" => index }
  end

  def split_atoms(cell)
    unescape(cell).split("|||").map(&:strip).reject(&:empty?)
  end

  # A decision column holds a JSON array whose single element is a "|||"-joined
  # list of the options the respondent sorted into that pile.
  def decision_atoms(cell)
    raw = cell.to_s.strip
    return [] if raw.empty? || raw == "[]"

    parsed =
      begin
        JSON.parse(raw)
      rescue JSON::ParserError
        [ raw ]
      end
    Array(parsed).flat_map { |chunk| split_atoms(chunk) }
  end

  # The three tap_card piles, from up to three columns. When the export has no
  # explicit third column, "unsure" is what's left over — an option the
  # respondent sorted into neither pile. When it does have one ("I don't
  # know"), that column is read rather than inferred, so an option nobody
  # sorted at all stays unsure either way.
  def tap_value(row, cols, options)
    piles = %i[yes no unsure].index_with do |pile|
      cols[pile] ? decision_atoms(row[cols[pile]]).map { |a| canonical(a, options) } : []
    end
    piles.each { |pile, values| (values - options).each { |a| record_unmatched(cols[pile], a) } }
    return nil if piles.values.all?(&:empty?)

    value = options.index_with do |opt|
      piles.keys.find { |pile| piles[pile].include?(opt) }&.to_s || "unsure"
    end
    { "type" => "tap_card", "value" => value }
  end

  def matrix_index(cell)
    digits = cell.to_s.strip[/\d+/]
    return nil unless digits

    [ [ digits.to_i - 1, 0 ].max, 4 ].min
  end

  def difficult_value(cell)
    v = cell.to_s.strip
    return nil if v.empty?

    # "Other (please share) [free text]" — matched on the bracketed-suffix
    # SHAPE, not the English prefix, so a localized export's Other rows keep
    # their free text instead of becoming a one-off value bucket.
    if v =~ /\A[^\[\]]+\(([^()\[\]]+)\)\s*\[(.*)\]\s*\z/m
      { "type" => "multiple_choice", "value" => nil, "other" => Regexp.last_match(2).to_s.strip.presence }.compact
    else
      cv = canonical(v, DIFFICULT_OPTS)
      record_unmatched("What makes it difficult for you to take part in sport regularly? (pickOne)", v) unless DIFFICULT_OPTS.include?(cv)
      { "type" => "multiple_choice", "value" => cv }
    end
  end

  def born_value(cell)
    v = cell.to_s.strip
    return nil unless v =~ /\A(\d{4})-(\d{2})/

    { "type" => "open_ended", "value" => "#{Regexp.last_match(1)}-#{Regexp.last_match(2)}" }
  end

  # Resolves a free-text country/place name to the "CC|Label" the location card
  # stores (label = the city segment for a "City, Country" value, else the
  # country name). Returns the raw text when the country can't be resolved.
  def resolve_location(raw)
    s = raw.to_s.strip
    return nil if s.empty?

    s = s.sub(/\A\[OTHER\]\s*/i, "").strip
    segments = s.split(",").map(&:strip).reject(&:empty?)
    matched  = nil
    code = ([ s ] + segments).uniq.each do |candidate|
      hit = COUNTRY_ALIASES[candidate.downcase] || @name_to_code[candidate.downcase]
      if hit
        matched = candidate
        break hit
      end
    end
    return s unless code.is_a?(String)

    label =
      if matched == s
        WorldRegions.name_for(code)
      else
        (segments.find { |seg| seg.downcase != matched.downcase } || WorldRegions.name_for(code))
      end
    "#{code}|#{label.to_s.first(60)}"
  end

  # Reads the resolved "CC|Label" location answer back into region columns,
  # mirroring PlayerController#sync_region_from_answers! (only a WorldRegions
  # country is kept; anything else leaves the response untagged).
  #
  # It is handed the LOCATION spec's own answer (spec `demo: :region`). It used
  # to scan the whole answers hash for the first open_ended value containing a
  # "|", which in any deck with free text before the location card meant a
  # respondent who typed a pipe into a free-text box lost their country tag —
  # silently, and while their country sat correctly in the same hash.
  def region_from(value)
    return [ nil, nil ] if value.to_s.empty?

    country, label = value.to_s.split("|", 2)
    return [ nil, nil ] unless WorldRegions.valid?(country)

    [ country.upcase, label.to_s.strip.first(60) ]
  end

  def parse_created_at(date, time)
    d = date.to_s.strip
    return nil if d.empty?

    has_time = !time.to_s.strip.empty?
    str = has_time ? "#{d} #{time.strip}" : d
    fmt = has_time ? "%d/%m/%Y %I:%M:%S %p" : "%d/%m/%Y"
    Time.zone.parse(DateTime.strptime(str, fmt).to_s)
  rescue ArgumentError
    nil
  end
end
