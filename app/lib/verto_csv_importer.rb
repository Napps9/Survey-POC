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
    "korea, republic of" => "KR", "south korea" => "KR", "republic of korea" => "KR",
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

  def initialize(csv_path:, admin_password:,
                 org_name: DEFAULT_ORG_NAME, org_slug: DEFAULT_ORG_SLUG,
                 admin_email: DEFAULT_ADMIN_EMAIL, admin_name: nil,
                 title: DEFAULT_TITLE, verto_slug: DEFAULT_VERTO_SLUG)
    @csv_path       = csv_path
    @admin_password = admin_password
    @org_name       = org_name
    @org_slug       = org_slug
    @admin_email    = admin_email
    @admin_name     = admin_name || "#{org_name} Admin"
    @title          = title
    @verto_slug     = verto_slug
    @name_to_code   = WorldRegions::COUNTRIES.map { |code, c| [ c[:name].downcase, code ] }.to_h
  end

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
      rows.each { |row| import_row!(survey, specs, row) }
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
      regions:    "#{tagged.count} tagged across #{tagged.distinct.count(:region_country)} countries"
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

  def import_row!(survey, specs, row)
    token = row["Viewing ID"].to_s.strip
    return if token.empty?

    answers = {}
    specs.each_with_index do |spec, idx|
      source = spec[:col] || spec[:cols]
      next unless source

      entry = spec[:get].call(row, source)
      answers[idx.to_s] = entry if entry
    end

    country, label = region_from(answers)
    created = parse_created_at(row["Start date"], row["Start time"]) || Time.current

    Response.create!(
      survey: survey, session_token: "#{@org_slug}-#{token}",
      status: (row["Completion percentage"].to_f >= 100.0 ? "completed" : "started"),
      answers: answers,
      region_country: country, region_label: label,
      locale: row["Language"].to_s.strip.presence || "en",
      created_at: created, updated_at: created
    )
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
      get: ->(row, source) { range_entry(lookup.call(row[source])) } }
  end

  def matrix_spec(statement)
    col = "Playing sport or being active helps me… - #{statement} (matrix)"
    { card: { "type" => "range", "text" => "Playing sport or being active helps me… #{statement}", "options" => AGREE },
      col: col, get: ->(row, source) { range_entry(matrix_index(row[source])) } }
  end

  def rating_spec(text, options, col)
    lookup = indexer(options)
    { card: { "type" => "rating", "text" => text, "options" => options }, col: col,
      get: ->(row, source) {
        i = lookup.call(row[source])
        i.nil? ? nil : { "type" => "rating", "value" => i + 1 }
      } }
  end

  def pick_one_spec(text, options, col)
    { card: { "type" => "multiple_choice", "text" => text, "options" => options }, col: col,
      get: ->(row, source) {
        v = row[source].to_s.strip
        v.empty? ? nil : { "type" => "multiple_choice", "value" => v }
      } }
  end

  def pick_many_spec(text, options, col)
    { card: { "type" => "select_many", "text" => text, "options" => options }, col: col,
      get: ->(row, source) {
        atoms = split_atoms(row[source])
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
        GENDER_OPTS.include?(v) ? { "type" => "multiple_choice", "value" => v } : nil
      } }
  end

  # ── value coercion helpers ────────────────────────────────────────────────

  # Maps an ordered options list to a ->(text) { index } lookup (nil if absent).
  def indexer(options)
    lut = options.each_with_index.to_h { |o, i| [ o, i ] }
    ->(text) { lut[text.to_s.strip] }
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
    yes = decision_atoms(row[cols[:yes]])
    no  = decision_atoms(row[cols[:no]])
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

    if v =~ /\AOther \(please share\)\s*\[(.*)\]\s*\z/m
      { "type" => "multiple_choice", "value" => nil, "other" => Regexp.last_match(1).to_s.strip.presence }.compact
    else
      { "type" => "multiple_choice", "value" => v }
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
