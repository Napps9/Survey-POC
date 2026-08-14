# The only door into the Ask Verto corpus.
#
# Three tools, and every one of them starts from CorpusEntry.citable. There is no
# method here that takes a relation, an organisation, or a survey id from outside
# — the caller cannot widen what a tool can see, because there is no parameter
# that would let them. That is deliberate: this is the one place in the app that
# reads across organisation boundaries, and the app's every other rule ("scope to
# Current.organisation") is inverted here. One entry point is what makes that
# reviewable.
#
# ── Why this exists at all ─────────────────────────────────────────────────────
# Claude never sees the corpus as a prompt dump. It calls a tool, and the tool
# returns rows that Ruby has stamped with a source number. The model can only
# cite a number it was handed, so a citation is a structural fact rather than an
# instruction it was asked to follow. `sources` accumulates those stampings for
# the turn; AskVertoChat validates the model's markers against it.
class CorpusTools
  # Cap on how much one search returns. Enough to find the right question,
  # small enough that the model reads all of it.
  SEARCH_LIMIT = 12
  # Cap on questions fetched in one go, so a single tool call can't pull the
  # whole corpus into the context window.
  FETCH_LIMIT = 6
  # Quotes shown per question in a tool result.
  QUOTE_LIMIT = 4
  # Segments returned by one get_breakdown call, and how many of a dimension's
  # segments are NAMED (never valued) in the summary a fetched question carries.
  BREAKDOWN_SEGMENT_LIMIT = 25
  BREAKDOWN_NAME_LIMIT    = 3

  DEFINITIONS = [
    {
      name: "search_corpus",
      description: <<~DESC,
        Find survey questions in the corpus that relate to a topic. Returns matching
        questions with their Verto, sample size and answer options — but NOT their
        results. Call get_questions with the ids you want the numbers for.
        Search by plain keywords. If a search returns nothing, try broader or
        different words before concluding the corpus has no data on the topic.
      DESC
      input_schema: {
        type: "object",
        properties: {
          query:   { type: "string", description: "Keywords to match against question wording, theme and answer options." },
          theme:   { type: "string", description: "Optional. Restrict to a theme, e.g. 'Climate Action'." },
          country: { type: "string", description: "Optional. ISO country code, e.g. 'CL'." }
        },
        required: [ "query" ]
      }
    },
    {
      name: "get_questions",
      description: <<~DESC,
        Fetch full results for up to #{FETCH_LIMIT} questions by id: every answer option
        with its count and percentage, the sample size, and — for open-text questions
        — themes with counts and quotes. Demographic and country splits are NAMED
        here, not included; call get_breakdown for the numbers behind one.
        Each result carries a "source" number. Use that number to cite it.
      DESC
      input_schema: {
        type: "object",
        properties: {
          ids: { type: "array", items: { type: "integer" },
                 description: "Question ids returned by search_corpus." }
        },
        required: [ "ids" ]
      }
    },
    {
      name: "get_breakdown",
      description: <<~DESC,
        Fetch one question's results split by ONE dimension — how the answers differ
        by country, gender, age band, or how the data was collected. A fetched
        question tells you which dimensions it has and how many segments each holds;
        this is how you get the numbers behind one of them.
        Returns at most #{BREAKDOWN_SEGMENT_LIMIT} segments, largest first, under the
        SAME source number as the question itself — cite a segment figure with that
        number.
      DESC
      input_schema: {
        type: "object",
        properties: {
          question_id: { type: "integer", description: "The question's id, as returned by search_corpus or get_questions." },
          dimension:   { type: "string", description: "One of the dimension names the question listed, e.g. 'Country', 'Gender', 'Age'." },
          limit:       { type: "integer", description: "Optional. Segments to return, up to #{BREAKDOWN_SEGMENT_LIMIT}." }
        },
        required: [ "question_id", "dimension" ]
      }
    },
    {
      name: "list_vertos",
      description: <<~DESC,
        List the surveys in the corpus: name, organisation, theme, country, when it
        was fielded and how many people completed it. Use this to answer questions
        about coverage ("what data do you have on X?") or to decide which surveys
        are worth searching.
      DESC
      input_schema: {
        type: "object",
        properties: {
          theme:   { type: "string", description: "Optional. Filter by theme." },
          country: { type: "string", description: "Optional. ISO country code." }
        },
        required: []
      }
    }
  ].freeze

  # Sources stamped this turn: source number => the row it came from. AskVertoChat
  # reads this to resolve the model's markers and to build the source rail.
  attr_reader :sources

  def initialize(scope: {})
    @scope   = scope.to_h.symbolize_keys
    @sources = []
    @by_question_id = {}
  end

  def definitions = DEFINITIONS

  # Dispatch. An unknown tool name returns an error the model can read and
  # recover from rather than raising — a malformed tool call should cost a turn,
  # not the conversation.
  def call(name, input)
    case name.to_s
    when "search_corpus" then search_corpus(input)
    when "get_questions" then get_questions(input)
    when "get_breakdown" then get_breakdown(input)
    when "list_vertos"   then list_vertos(input)
    else { error: "Unknown tool #{name}." }
    end
  rescue => e
    ErrorReporting.report("CorpusTools##{name}", e)
    { error: "That lookup failed. Try a different search." }
  end

  # How much of the corpus this conversation can see. Shown to the user, and put
  # in the system prompt so the model knows its own denominator.
  def coverage
    entries = scoped_entries
    {
      vertos:    entries.count,
      responses: entries.sum(:response_count),
      countries: entries.joins(survey: :responses)
                        .where.not(responses: { region_country: nil })
                        .distinct.count("responses.region_country")
    }
  end

  # Opening questions for the empty screen.
  #
  # Derived, never invented. Each one is built from something the corpus actually
  # holds — a theme with enough questions behind it to answer, the largest
  # open-text question, a country split that exists. A suggestion that returns
  # "I don't have data on that" is worse than no suggestion, so nothing is
  # offered unless the data behind it is already there.
  #
  # It also means these are a DISCLOSURE: the chips name themes from the corpus,
  # so they must be built from `citable` like everything else here. A withdrawn
  # Verto's themes must not survive on the front page.
  MAX_SUGGESTIONS = 6

  def suggestions
    questions = base_questions.to_a
    return [] if questions.empty?

    out = []

    # The UN goals the corpus can actually speak to, ranked by the people
    # behind them, each tile in the goal's own official colour. Derived like
    # every other suggestion: a goal no citable Verto declares is never
    # offered, so a withdrawn Verto's goals leave the front page with it.
    sdg_tallies = Hash.new(0)
    scoped_entries.includes(:survey).each do |entry|
      UnSdgs.sanitize(entry.survey.sdgs).each { |n| sdg_tallies[n] += entry.response_count }
    end
    sdg_tallies.sort_by { |_n, responses| -responses }.first(3).each do |n, _responses|
      out << {
        label:    UnSdgs.label(n),
        question: I18n.t("ask.suggest.sdg", goal: UnSdgs.title(n)),
        accent:   UnSdgs.color(n),
        icon:     n.to_s,
        meta:     "#{UnSdgs.label(n)} · #{UnSdgs.title(n)}"
      }
    end

    # The best-covered themes. Two questions minimum, so there is something to
    # compare rather than one card to recite.
    questions.group_by { |q| q.theme.presence }.compact
             .reject { |_theme, group| group.size < 2 }
             .sort_by { |_theme, group| -group.sum(&:response_count) }
             .first(3)
             .each do |theme, group|
      out << {
        label:    theme,
        question: I18n.t("ask.suggest.theme", theme: theme.downcase),
        accent:   CardTypes.accent(group.max_by(&:response_count).card_type),
        icon:     CardTypes.icon(group.max_by(&:response_count).card_type),
        meta:     I18n.t("ask.suggest.meta_questions", count: group.size)
      }
    end

    # Open text, if any survived redaction into quotable form.
    open_text = questions.select(&:open_text?).max_by(&:response_count)
    if open_text
      out << {
        label:    I18n.t("ask.suggest.own_words_label"),
        question: I18n.t("ask.suggest.own_words"),
        accent:   CardTypes.accent("open_ended"),
        icon:     CardTypes.icon("open_ended"),
        meta:     I18n.t("ask.suggest.meta_responses", count: open_text.response_count)
      }
    end

    # A country split, only when there is genuinely more than one.
    if coverage[:countries] > 1
      out << {
        label:    I18n.t("ask.suggest.countries_label"),
        question: I18n.t("ask.suggest.countries"),
        accent:   "#0CA7FF",
        icon:     "🌍",
        meta:     I18n.t("ask.suggest.meta_countries", count: coverage[:countries])
      }
    end

    # Agreement across Vertos, only when a theme actually spans two of them.
    shared = questions.group_by { |q| q.theme.presence }.compact
                      .find { |_theme, group| group.map(&:corpus_entry_id).uniq.size > 1 }
    if shared
      out << {
        label:    I18n.t("ask.suggest.agreement_label"),
        question: I18n.t("ask.suggest.agreement", theme: shared.first.downcase),
        accent:   "#01EACB",
        icon:     "⇌",
        meta:     I18n.t("ask.suggest.meta_vertos", count: shared.last.map(&:corpus_entry_id).uniq.size)
      }
    end

    out.first(MAX_SUGGESTIONS)
  end

  private

  # THE gate. Everything below starts here.
  def scoped_entries
    entries = CorpusEntry.citable
    entries = entries.where(id: entries_matching_country) if @scope[:country].present?
    entries
  end

  def entries_matching_country
    CorpusEntry.citable.joins(:survey)
               .joins("JOIN responses ON responses.survey_id = surveys.id")
               .where(responses: { region_country: @scope[:country] })
               .distinct.select(:id)
  end

  def base_questions
    CorpusQuestion.where(corpus_entry_id: scoped_entries.select(:id))
                  .includes(corpus_entry: :survey)
  end

  # ── search_corpus ─────────────────────────────────────────────────────────
  # Deliberately simple keyword matching over question text, theme and options.
  # Its weakness is paraphrase — "anxious about the future" will not match
  # "worried about what comes next" — which is why the tool description tells the
  # model to retry with different words, and why list_vertos exists as a way to
  # see what is there without guessing the wording.
  def search_corpus(input)
    terms = input["query"].to_s.downcase.split(/\W+/).reject { |t| t.length < 3 }
    return { questions: [], note: "Give me some keywords to search for." } if terms.empty?

    relation = base_questions
    relation = relation.where("LOWER(theme) LIKE ?", "%#{sanitize(input["theme"].to_s.downcase)}%") if input["theme"].present?

    # `options` is a json column, and Postgres has no LOWER(json) — the cast is
    # what lets the same clause run on SQLite in dev and Postgres in prod.
    clause = terms.map { "(LOWER(question_text) LIKE ? OR LOWER(theme) LIKE ? OR LOWER(CAST(options AS TEXT)) LIKE ?)" }.join(" OR ")
    args   = terms.flat_map { |t| [ "%#{sanitize(t)}%" ] * 3 }

    matches = relation.where(clause, *args).order(response_count: :desc).limit(SEARCH_LIMIT)

    {
      questions: matches.map { |q| summary_row(q) },
      note: matches.empty? ? "No questions matched those words. Try broader terms, or call list_vertos to see what the corpus covers." : nil
    }.compact
  end

  # ── get_questions ─────────────────────────────────────────────────────────
  def get_questions(input)
    ids = Array(input["ids"]).map(&:to_i).uniq.first(FETCH_LIMIT)
    return { error: "Give me question ids from search_corpus." } if ids.empty?

    rows = base_questions.where(id: ids).map { |q| result_row(q) }
    return { error: "None of those ids are in the corpus." } if rows.empty?

    { results: rows }
  end

  # ── get_breakdown ─────────────────────────────────────────────────────────
  # One question, one dimension. This exists because the alternative — handing
  # over every segment with every fetched question — is what a question's
  # `segments` column actually holds, and on a Verto fielded in 124 countries
  # that is tens of thousands of tokens per question, paid again on every
  # subsequent round. `result_row` therefore NAMES the dimensions and this
  # fetches one.
  #
  # The distinction that matters: the old top-8 cap dropped 211 countries
  # SILENTLY (see SegmentAggregator's comment on why it was removed). Nothing
  # is dropped here — the summary says the dimension holds 124, and this
  # returns them a page at a time. Absent is absent; deferred is deferred.
  def get_breakdown(input)
    question = base_questions.find_by(id: input["question_id"].to_i)
    return { error: "That question id is not in the corpus." } if question.nil?

    grouped = segments_by_dimension(question)
    wanted  = grouped.keys.find { |d| d.casecmp?(input["dimension"].to_s.strip) }
    if wanted.nil?
      return { error: "That question has no #{input['dimension']} breakdown.",
               dimensions: grouped.keys }
    end

    rows  = grouped[wanted]
    limit = input["limit"].to_i
    limit = BREAKDOWN_SEGMENT_LIMIT unless limit.positive?
    shown = rows.first([ limit, BREAKDOWN_SEGMENT_LIMIT ].min)

    out = {
      # The same number the question was stamped with — a segment figure is a
      # figure from that question, so it cites as that question.
      source:    stamp(question),
      question:  question.question_text,
      dimension: wanted,
      segments:  shown.map { |label, cell| breakdown_segment(label, cell) }
    }
    if rows.size > shown.size
      out[:omitted] = rows.size - shown.size
      out[:note]    = "#{out[:omitted]} more #{wanted.downcase} segments exist. Ask for them with a higher limit."
    end
    out
  end

  # {"Country: Kenya" => {...}} → {"Country" => [["Kenya", {...}], ...]},
  # each dimension's segments largest first. A label with no dimension prefix
  # is grouped under "Other" rather than dropped.
  def segments_by_dimension(question)
    segments = question.segments
    return {} unless segments.is_a?(Hash)

    segments.each_with_object({}) do |(label, cell), out|
      dimension, value = label.to_s.split(": ", 2)
      dimension, value = "Other", label.to_s if value.nil?
      (out[dimension] ||= []) << [ value, cell ]
    end.each_value { |rows| rows.sort_by! { |_value, cell| -cell.to_h["n"].to_i } }
  end

  # One segment's answers, shaped like a question's own. Percentages are
  # computed the same way CorpusQuestion#ranked_options computes them, so a
  # segment's share and a whole-Verto share are rounded by one rule.
  def breakdown_segment(value, cell)
    counts = cell.to_h["distribution"].to_h
    total  = counts.values.sum { |v| v.to_i }
    answers = counts.sort_by { |_label, v| -v.to_i }.map do |label, count|
      { label: label.to_s, count: count.to_i,
        percent: total.zero? ? 0.0 : (count.to_i * 100.0 / total).round(1) }
    end

    { segment: value, responses: cell.to_h["n"].to_i, answers: answers }
  end

  # ── list_vertos ───────────────────────────────────────────────────────────
  def list_vertos(input)
    entries = scoped_entries.includes(:survey, :organisation)
    # An id subquery, not joins+distinct: corpus_entries carries json columns,
    # and Postgres cannot DISTINCT a row that contains one.
    if input["theme"].present?
      themed = CorpusQuestion.where("LOWER(theme) LIKE ?", "%#{sanitize(input["theme"].to_s.downcase)}%")
                             .select(:corpus_entry_id)
      entries = entries.where(id: themed)
    end

    { vertos: entries.map { |e| verto_row(e) } }
  end

  # ── Row builders ──────────────────────────────────────────────────────────

  def verto_row(entry)
    {
      verto:        entry.survey.title.presence || entry.survey.theme,
      organisation: entry.organisation.name,
      theme:        entry.survey.theme,
      completed_responses: entry.response_count,
      fielded:      fielded_window(entry),
      languages:    Array(entry.survey.locales).presence || [ entry.survey.default_locale ],
      questions:    entry.corpus_questions.size
    }
  end

  # Search results carry no numbers. That keeps a search cheap, and it means the
  # model has to fetch a question before it can say anything about it — which is
  # the step that stamps a source.
  def summary_row(question)
    {
      id:       question.id,
      question: question.question_text,
      type:     question.card_type,
      options:  question.option_labels,
      responses: question.response_count,
      verto:    question.corpus_entry.survey.title.presence || question.corpus_entry.survey.theme,
      organisation: question.corpus_entry.organisation.name,
      theme:    question.theme
    }
  end

  # A fetched question, stamped with its source number. The stamping is the
  # citation: the model is handed "source: 3" and can only write [[c:3]] for a
  # row it was actually given.
  def result_row(question)
    number = stamp(question)
    entry  = question.corpus_entry

    row = {
      source:   number,
      question: question.question_text,
      type:     question.card_type,
      verto:    entry.survey.title.presence || entry.survey.theme,
      organisation: entry.organisation.name,
      responses: question.response_count,
      fielded:  fielded_window(entry)
    }

    case question.card_type
    when "prioritise"
      # Never a count. Say what it is, in words, every time it is handed over.
      row[:mean_rank] = question.distribution["mean_rank"]
      row[:reading]   = "Mean position when respondents ordered the list — LOWER means HIGHER priority. These are not counts."
    when "open_ended"
      row[:responses] = question.distribution["responses"].to_i
      row[:themes]    = Array(question.distribution["themes"])
      # A theme count and a response count are taken over DIFFERENT numbers of
      # people — redaction removes answers before theming sees them, and a very
      # large column is themed across a stride. Handed over side by side with
      # nothing distinguishing them, "Cost: 40" reads as 40 of the responses.
      themed = question.distribution["themed_over"].to_i
      if themed.positive? && themed != row[:responses]
        row[:themes_counted_over] = themed
        row[:reading] = "Theme counts are out of #{themed} answers read, NOT the #{row[:responses]} responses. " \
                        "Cite a theme as a share of the answers read, or not as a number at all."
      end
      row[:quotes]    = question.quotes.limit(QUOTE_LIMIT).map { |q| { quote: q.id, theme: q.theme } }
      row[:quote_note] = "Refer to a quote as [[q:<id>]] using the quote id. Do NOT retype the words — the page prints them."
    when "rating"
      row[:average] = question.average
      row[:answers] = question.ranked_options
    else
      row[:answers] = question.ranked_options
    end

    # Which splits exist, NOT the splits themselves. See get_breakdown.
    summary = breakdown_dimensions(question)
    row[:breakdowns] = summary if summary
    row
  end

  # A fetched question's splits, named and counted but never valued.
  #
  # `segments` is the biggest thing a corpus_question carries — one WLL question
  # holds ~124 country cells plus gender, age and collection mode, each with a
  # full distribution — and it used to ride out whole on every fetched question.
  # Six of those is a tool result in the tens of thousands of tokens, re-sent on
  # every later round, which is most of what made an answer slow AND why one
  # Verto's questions crowded every other Verto out of the context window.
  #
  # `largest` names three segments and carries no numbers at all. Naming them is
  # what lets the model decide whether a split is worth a get_breakdown call; a
  # count beside a name would be read as a result.
  def breakdown_dimensions(question)
    grouped = segments_by_dimension(question)
    return nil if grouped.empty?

    {
      "note" => "These splits are not shown here. Call get_breakdown with this " \
                "question's id and one dimension for the numbers behind it.",
      "dimensions" => grouped.map do |dimension, rows|
        { "dimension" => dimension,
          "segments"  => rows.size,
          "largest"   => rows.first(BREAKDOWN_NAME_LIMIT).map(&:first) }
      end
    }
  end

  # Assign (or reuse) this turn's source number for a question. Reused so the
  # same question fetched twice is [[c:2]] both times rather than two entries in
  # the rail describing one source.
  def stamp(question)
    existing = @by_question_id[question.id]
    return existing if existing

    number = @sources.size + 1
    @by_question_id[question.id] = number
    entry = question.corpus_entry

    @sources << {
      "n"                  => number,
      "corpus_question_id" => question.id,
      "question"           => question.question_text,
      "card_type"          => question.card_type,
      "verto"              => entry.survey.title.presence || entry.survey.theme,
      "organisation"       => entry.organisation.name,
      "responses"          => question.response_count,
      "fielded"            => fielded_window(entry),
      "theme"              => question.theme,
      # Display-only provenance for the source rail and detail panel. Not in
      # result_row, deliberately: the model has no validated way to make SDG
      # claims, so it is not handed the tags to claim with.
      "sdgs"               => entry.survey.sdgs,
      # Presentation, carried on the source so the live stream and the
      # server-rendered replay colour a citation identically without either
      # having to look the type up again.
      #
      # `accent` is the question TYPE's hue — what kind of evidence this is.
      # `brand` is the VERTO's own primary — which study it came from. Both are
      # on the card; only the accent reaches the inline chip, because a chip is
      # too small to carry two signals.
      "accent"             => CardTypes.accent(question.card_type),
      "icon"               => CardTypes.icon(question.card_type),
      "brand"              => entry.survey.brand_palette["primary"],
      # The Detail pane's answer bars: every option (or open-text theme) with
      # its share, largest first. Display-only, like `sdgs` — result_row hands
      # the model richer, labelled numbers; this is the pane's snapshot of the
      # same facts, so a reader can see the whole distribution behind a cited
      # figure without a second fetch. Absent on pre-breakdown snapshots,
      # which render as they always did.
      "breakdown"          => breakdown_for(question)
    }
    number
  end

  # At most this many bars in a Detail pane breakdown — enough to show the
  # shape of a distribution, few enough to stay a glance.
  BREAKDOWN_LIMIT = 8

  def breakdown_for(question)
    rows =
      case question.card_type
      when "prioritise"
        # A mean rank is not a count — a bar would read as a share of people,
        # which is exactly the misreading result_row spells out against.
        []
      when "open_ended"
        themes = Array(question.distribution["themes"])
        total  = themes.sum { |theme| theme["count"].to_i }
        themes.map do |theme|
          count = theme["count"].to_i
          { "label"   => theme["label"].to_s,
            "count"   => count,
            "percent" => total.zero? ? 0 : (count * 100.0 / total).round(1) }
        end
      else
        question.ranked_options.map do |option|
          { "label" => option[:label], "count" => option[:count], "percent" => option[:percent] }
        end
      end

    rows.first(BREAKDOWN_LIMIT)
  end

  # Month precision, not timestamps. "3 June 2025, 14:02" narrows a respondent
  # far more than "June 2025" and answers no question anyone is asking.
  def fielded_window(entry)
    # The same population the corpus counts — every respondent who answered
    # something, not only the ones who reached the last card.
    answered = CorpusIndexer.countable_responses(entry.survey)
    first = answered.minimum(:created_at)
    last  = answered.maximum(:created_at)
    return nil if first.nil?

    from = first.strftime("%b %Y")
    to   = last.strftime("%b %Y")
    from == to ? from : "#{from} – #{to}"
  end

  # LIKE wildcards in a user-supplied term would otherwise let a search match
  # everything; the bind parameter stops injection, this stops the wildcards.
  def sanitize(term) = ActiveRecord::Base.sanitize_sql_like(term)
end
