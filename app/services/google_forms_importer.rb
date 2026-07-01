# Maps a Google Forms API form Hash to the import `result` payload that
# SurveysController#create_imported_survey! consumes (the same shape
# PdfQuestionImporter emits). Questions are kept VERBATIM and each is assigned
# the best-fitting Verto card type; the creator then optimises them with the
# editor's built-in per-card "Optimise" once the Verto opens.
#
# - choiceQuestion RADIO/DROP_DOWN → multiple_choice, CHECKBOX → select_many
# - scaleQuestion  → nps for a 0–10-ish scale, otherwise range
# - ratingQuestion → rating
# - textQuestion   → open_ended   ·   date/time → open_ended (date input)
# - questionGroupItem (grid/matrix) → one choice question per row
# - fileUpload / page break / image / video items are skipped (no equivalent)
class GoogleFormsImporter
  def self.call(form)
    new(form).call
  end

  def initialize(form)
    @form = form.is_a?(Hash) ? form : {}
  end

  def call
    info  = @form["info"] || {}
    cards = Array(@form["items"]).flat_map { |item| cards_for(item) }.compact

    {
      "title"       => info["title"].to_s.strip.presence || info["documentTitle"].to_s.strip.presence,
      "description" => info["description"].to_s.strip.presence,
      "cards"       => cards
    }
  end

  private

  def cards_for(item)
    if (qi = item["questionItem"])
      c = question_card(item["title"], qi["question"] || {})
      c ? [ c ] : []
    elsif (gi = item["questionGroupItem"])
      group_cards(item, gi)
    else
      [] # textItem / pageBreakItem / imageItem / videoItem — nothing to answer
    end
  end

  def question_card(title, question)
    text = title.to_s.strip
    return nil if text.blank?

    if (cq = question["choiceQuestion"])
      type = cq["type"] == "CHECKBOX" ? "select_many" : "multiple_choice"
      card(text, type, choice_options(cq))
    elsif (sq = question["scaleQuestion"])
      low  = sq["low"].to_i
      high = sq["high"].to_i
      high = low + 1 if high <= low
      labels = (low..high).map(&:to_s)
      # A 0–10-ish scale reads as NPS; a shorter one as a range slider.
      type = (low <= 0 && high >= 8) ? "nps" : "range"
      card(text, type, labels)
    elsif question["ratingQuestion"]
      card(text, "rating", [])
    elsif question["textQuestion"]
      card(text, "open_ended", [])
    elsif question["dateQuestion"] || question["timeQuestion"]
      card(text, "open_ended", []).merge("input" => "date")
    end
    # fileUploadQuestion and anything unknown → nil (skipped)
  end

  # A matrix/grid: one choice question per row, sharing the grid's columns as
  # options. The row title is folded into the question text so each stands alone.
  def group_cards(item, group_item)
    columns = choice_options(group_item.dig("grid", "columns") || {})
    multi   = group_item.dig("grid", "columns", "type") == "CHECKBOX"
    prompt  = item["title"].to_s.strip

    Array(group_item["questions"]).filter_map do |row|
      row_text = row.dig("rowQuestion", "title").to_s.strip
      next if row_text.blank?

      text = [ prompt, row_text ].reject(&:blank?).join(" — ")
      card(text, multi ? "select_many" : "multiple_choice", columns)
    end
  end

  def choice_options(choice_question)
    Array(choice_question["options"])
      .map { |o| o["value"].to_s.strip }
      .reject(&:blank?)
  end

  def card(text, type, options)
    c = { "type" => type, "text" => text, "original_text" => text }
    c["options"] = options if options.present?
    c
  end
end
