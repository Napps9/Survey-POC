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

  def initialize(csv_path:, admin_password: nil,
                 org_name: DEFAULT_ORG_NAME, org_slug: DEFAULT_ORG_SLUG,
                 admin_email: DEFAULT_ADMIN_EMAIL, admin_name: nil,
                 title: DEFAULT_TITLE, verto_slug: DEFAULT_VERTO_SLUG,
                 translations: nil)
    @csv_path       = csv_path
    @admin_password = admin_password
    @org_name       = org_name
    @org_slug       = org_slug
    @admin_email    = admin_email
    @admin_name     = admin_name || "#{org_name} Admin"
    @title          = title
    @verto_slug     = verto_slug
    @name_to_code   = WorldRegions::COUNTRIES.map { |code, c| [ c[:name].downcase, code ] }.to_h
    # Optional sidecar mapping translated answer labels → the canonical English
    # option, for survey-specific lists our locale files can't know about.
    # Defaults to "<csv>.translations.yml" next to the export when it exists.
    @translations_path = translations || default_translations_path
    @unmatched = Hash.new { |h, k| h[k] = Hash.new(0) }
  end

  # { column header => { raw value => count } } of answer values that matched
  # no option in ANY language — i.e. what the import dropped (scales) or passed
  # through as its own bucket (choices). Empty after a clean import; anything
  # here is the first place to look when counts seem low.
  attr_reader :unmatched

  # Builds the account + Verto + responses in one transaction. Returns the Survey.
  def call
    require_password!
    rows  = CSV.read(@csv_path, headers: true, encoding: "bom|utf-8")
    specs = build_specs
    cards = specs.map { |s| s[:card] }

    survey = nil
    ActiveRecord::Base.transaction do
      destroy_existing!
      org = create_organisation!
      create_admin!(org)
      survey = create_survey!(org, cards)
      rows.each do |row|
        attrs = response_attributes(specs, row)
        survey.responses.create!(attrs) if attrs
      end
    end
    survey
  end

  # Upsert the CSV into an EXISTING account + Verto instead of rebuilding: adds
  # responses that are new to this export and refreshes ones already imported,
  # keyed on the deterministic "<slug>-<Viewing ID>" token. The org, admin,
  # Verto (and its /play link) and any organically-collected responses (which
  # carry random tokens) are left untouched. Returns { survey:, added:, updated: }.
  def append!
    rows  = CSV.read(@csv_path, headers: true, encoding: "bom|utf-8")
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
      rows.each do |row|
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
                     "#{@unmatched.values.sum { |h| h.values.sum }} values across #{@unmatched.size} columns (see #unmatched)")
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
    Organisation.create!(name: @org_name, slug: @org_slug, default_brand_palette: BRAND_PALETTE)
  end

  def create_admin!(org)
    user = User.create!(name: @admin_name, email_address: @admin_email, password: @admin_password)
    Membership.create!(user: user, organisation: org, role: "admin")
    user
  end

  def create_survey!(org, cards)
    survey = Survey.create!(
      organisation: org, title: @title,
      theme: "sport, wellbeing and changemaking", audience_age: "youth",
      key_insight: "How young people experience sport — activity, wellbeing, skills, access and voice.",
      default_locale: "en", locales: [ "en" ], cards: cards,
      show_results_comparison: true,
      compare_note: "See how your answers compare with everyone else who took part.",
      slug: (Survey.slug_taken?(@verto_slug) ? nil : @verto_slug),
      brand_palette: BRAND_PALETTE
    )
    survey.update!(publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
    survey
  end

  # Response attributes for one CSV row (nil when the row has no Viewing ID).
  # Shared by the full import (create) and append (upsert) so both derive the
  # same session token, answers, region, status and timestamp from a row.
  def response_attributes(specs, row)
    token = row["Viewing ID"].to_s.strip
    return nil if token.empty?

    answers = {}
    specs.each_with_index do |spec, idx|
      source = spec[:col] || spec[:cols]
      next unless source

      entry = spec[:get].call(row, source)
      answers[idx.to_s] = entry if entry
    end

    country, label = region_from(answers)
    created = parse_created_at(row["Start date"], row["Start time"]) || Time.current

    {
      session_token:  "#{@org_slug}-#{token}",
      status:         (row["Completion percentage"].to_f >= 100.0 ? "completed" : "started"),
      answers:        answers,
      region_country: country, region_label: label,
      locale:         row["Language"].to_s.strip.presence || "en",
      created_at:     created, updated_at: created
    }
  end

  # ── card deck + per-row extractors ────────────────────────────────────────
  # Each spec: { card:, col:/cols:, get: ->(row, source) => answer-entry|nil }.
  # Order here == card order == the positional string keys in `answers`.
  def build_specs
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

  def range_spec(text, options, col)
    lookup = indexer(options)
    { card: { "type" => "range", "text" => text, "options" => options }, col: col,
      get: ->(row, source) {
        i = lookup.call(row[source])
        record_unmatched(source, row[source]) if i.nil?
        range_entry(i)
      } }
  end

  def matrix_spec(statement)
    col = "Playing sport or being active helps me… - #{statement} (matrix)"
    agree = indexer(AGREE)
    { card: { "type" => "range", "text" => "Playing sport or being active helps me… #{statement}", "options" => AGREE },
      col: col, get: ->(row, source) {
        i = matrix_index(row[source]) || agree.call(row[source])
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

  def pick_one_spec(text, options, col)
    { card: { "type" => "multiple_choice", "text" => text, "options" => options }, col: col,
      get: ->(row, source) {
        v = row[source].to_s.strip
        next nil if v.empty?
        cv = canonical(v, options)
        record_unmatched(source, v) unless options.include?(cv)
        { "type" => "multiple_choice", "value" => cv }
      } }
  end

  def pick_many_spec(text, options, col)
    { card: { "type" => "select_many", "text" => text, "options" => options }, col: col,
      get: ->(row, source) {
        atoms = split_atoms(row[source]).map { |a| canonical(a, options) }
        atoms.each { |a| record_unmatched(source, a) unless options.include?(a) }
        atoms.empty? ? nil : { "type" => "select_many", "value" => atoms }
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
      col: "When were you born? (age)", get: ->(row, source) { born_value(row[source]) } }
  end

  def location_spec
    { card: { "type" => "open_ended", "input" => "location", "text" => "What country do you live in?",
              "description" => "Powered by OpenStreetMap — helps build a map you can explore after finishing.",
              "demographic" => true },
      col: "What country do you live in? (location)",
      get: ->(row, source) {
        loc = resolve_location(row[source])
        loc.nil? ? nil : { "type" => "open_ended", "value" => loc }
      } }
  end

  def gender_spec
    { card: { "type" => "multiple_choice", "text" => "What gender do you identify as?",
              "options" => GENDER_OPTS, "demographic" => true },
      col: "What gender do you identify as? (gender)",
      get: ->(row, source) {
        v = row[source].to_s.strip
        next nil if v.empty?
        cv = canonical(v, GENDER_OPTS)
        next record_unmatched(source, v) unless GENDER_OPTS.include?(cv)
        { "type" => "multiple_choice", "value" => cv }
      } }
  end

  # ── value coercion helpers ────────────────────────────────────────────────

  # Unify apostrophe variants and surrounding whitespace. The export mixes
  # curly (’) and straight (') apostrophes for the same label, so without this a
  # value like "No, I don't take part in sport" wouldn't match the reconstructed
  # "…don’t…" option — dropping the answer (scales) or splitting it into its own
  # results bucket (choices).
  def canon(text)
    text.to_s.strip.tr("’‘", "''")
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

  def range_entry(index)
    index.nil? ? nil : { "type" => "range", "value" => index }
  end

  def split_atoms(cell)
    cell.to_s.split("|||").map(&:strip).reject(&:empty?)
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

  def tap_value(row, cols, options)
    yes = decision_atoms(row[cols[:yes]]).map { |a| canonical(a, options) }
    no  = decision_atoms(row[cols[:no]]).map { |a| canonical(a, options) }
    (yes - options).each { |a| record_unmatched(cols[:yes], a) }
    (no  - options).each { |a| record_unmatched(cols[:no],  a) }
    return nil if yes.empty? && no.empty?

    value = options.index_with do |opt|
      if yes.include?(opt) then "yes"
      elsif no.include?(opt) then "no"
      else "unsure"
      end
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
  def region_from(answers)
    loc = answers.values.find { |e| e["type"] == "open_ended" && e["value"].to_s.include?("|") }
    return [ nil, nil ] unless loc

    country, label = loc["value"].split("|", 2)
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
