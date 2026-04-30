require "csv"

# Loads and searches the Playverto historical question corpus
# (app/questions.csv) so the survey generator can ground its output
# in proven wording and answer types.
class QuestionCorpus
  PATH = Rails.root.join("app/questions.csv")

  CATEGORY_TO_TYPE = {
    "pickOne"     => "multiple_choice",
    "select"      => "multiple_choice",
    "decision"    => "multiple_choice",
    "age"         => "multiple_choice",
    "gender"      => "multiple_choice",
    "location"    => "multiple_choice",
    "education"   => "multiple_choice",
    "pickMany"    => "select_many",
    "range"       => "range",
    "rating"      => "rating",
    "netPromoter" => "rating",
    "priority"    => "select_one_grid",
    "tap"         => "tap_card",
    "tapCard"     => "tap_card",
    "freeform"    => "open_ended"
  }.freeze

  STOPWORDS = %w[
    a an and are as at be but by for from has have he her his i in is it its
    of on or our she that the their them they this to was we were will with
    you your what which who whom whose why how when where do does did
  ].to_set.freeze

  class << self
    def all
      @all ||= load
    end

    def search(brief, limit: 15)
      tokens = tokenise(brief)
      return [] if tokens.empty?

      scored = all.map do |row|
        overlap = (row[:tokens] & tokens).size
        next nil if overlap.zero?
        score = overlap * 2.0 + Math.log10(row[:total_viewings] + 1)
        [score, row]
      end.compact

      scored.sort_by { |score, _| -score }.first(limit).map { |_, r| r }
    end

    def reload!
      @all = nil
      all
    end

    private

    def load
      return [] unless File.exist?(PATH)

      rows = []
      CSV.foreach(PATH, headers: true, liberal_parsing: true) do |row|
        text = clean_text(row["Question"])
        next if text.length < 3

        categories = parse_categories(row["Categories"])
        primary    = categories.max_by { |_, n| n }&.first
        rows << {
          question:         text,
          categories:       categories,
          primary_category: primary,
          primary_type:     CATEGORY_TO_TYPE[primary] || primary,
          total_viewings:   row["Total_Viewings"].to_i,
          appearances:      row["Appearances"].to_i,
          tokens:           tokenise(text)
        }.freeze
      rescue => e
        Rails.logger.warn("[QuestionCorpus] skipped row: #{e.message}")
      end
      rows
    rescue => e
      Rails.logger.error("[QuestionCorpus] load failed: #{e.message}")
      []
    end

    def clean_text(raw)
      return "" if raw.blank?
      s = raw.to_s
      # Strip Google-Sheets formatter pollution. The exporter dumps a payload like
      # ?...&quot;}"" data-sheets-userformat=""...""">REAL TEXT
      # We want everything AFTER the last `">` if that pattern is present.
      if s.include?("data-sheets-userformat")
        s = s.split(/"+>/).last.to_s
      end
      # Decode entity quotes / escaped quotes.
      s = s.gsub("&quot;", '"').gsub('\\"', '"')
      # Trim wrapping quotes / whitespace.
      s.strip.gsub(/\A"|"\z/, "").strip
    end

    def parse_categories(raw)
      return {} if raw.blank?
      raw.scan(/(\w+)\s*\((\d+)\)/).each_with_object({}) do |(tag, count), h|
        h[tag] = count.to_i
      end
    end

    def tokenise(text)
      text.to_s
          .downcase
          .gsub(/[^a-z0-9\s]/, " ")
          .split
          .reject { |t| t.length < 3 || STOPWORDS.include?(t) }
          .uniq
    end
  end
end
