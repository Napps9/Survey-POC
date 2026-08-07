# Per-question breakdowns by gender, age band and country, with small-cell
# suppression applied to every cell.
#
# The suppression rule is the important part and it is stricter than the one the
# results screen uses. Inside an account, a segment of five is shown because the
# creator already holds the raw responses — nothing is revealed that they cannot
# already see. Ask Verto publishes across an organisation boundary, so the floor
# is CorpusEntry::MIN_SAMPLE_SIZE (30) and it is applied per CELL, not per
# segment: a segment that clears 30 respondents overall can still fail on a single
# question that most of them skipped.
#
# A failing cell is DROPPED, never zeroed. A published "0" is as identifying as a
# published "1" — it says nobody in that group answered that way, which in a small
# group is a statement about named people. Absent means absent.
#
# Only single dimensions are computed. No gender × age, no age × country. Crosses
# are where re-identification actually happens, and the honest answer is not to
# store them at all rather than to store them and hope the floor holds.
class CorpusIndexer
  class SegmentAggregator
    include AggregatesSurveyResults

    # How many segments one Verto contributes, per dimension. A Verto fielded
    # across forty countries would otherwise multiply the index by forty for
    # diminishing value; the largest few are where the answers are.
    MAX_PER_DIMENSION = 8

    def initialize(survey, cards)
      @survey = survey
      @cards  = cards
    end

    # Returns { card_index => { segment_label => { "distribution" => {...}, "n" => 123 } } }
    def call
      base = @survey.responses.where(status: "completed")
      out  = Hash.new { |h, k| h[k] = {} }

      segments(base).each do |label, scope|
        aggregated = aggregate_results(@cards, scope)

        @cards.each_index do |idx|
          result = aggregated[idx]
          next if result.nil?

          n = result[:total].to_i
          # The cell rule. Below the floor this segment simply does not exist for
          # this question.
          next if n < CorpusEntry::MIN_SAMPLE_SIZE

          counts = countable(result)
          next if counts.blank?

          out[idx][label] = { "n" => n, "distribution" => counts }
        end
      end

      out
    end

    private

    # [[label, scope]] for every dimension, largest first, capped. Each scope is
    # already floored at MIN_SAMPLE_SIZE overall — a segment that can't clear it
    # in total will never clear it on a question.
    def segments(base)
      gender(base) + age(base) + country(base)
    end

    def gender(base)
      base.reorder(nil).where.not(demographic_gender: nil)
          .group(:demographic_gender).count
          .select { |_g, n| n >= CorpusEntry::MIN_SAMPLE_SIZE }
          .sort_by { |_g, n| -n }.first(MAX_PER_DIMENSION)
          .map { |gender, _n| [ "Gender: #{gender}", base.where(demographic_gender: gender) ] }
    end

    def age(base)
      this_year = Date.current.year

      ResolvesResultSegments::AGE_BANDS.filter_map do |label, min_age, max_age|
        scope = base.where(demographic_birth_year: (this_year - max_age)..(this_year - min_age))
        next if scope.reorder(nil).count < CorpusEntry::MIN_SAMPLE_SIZE

        [ "Age: #{label}", scope ]
      end.first(MAX_PER_DIMENSION)
    end

    # Country, not sub-region: a sub-region label plus an age band is a much
    # smaller group than either alone, and the map UI is country-granularity
    # everywhere else in the app anyway.
    def country(base)
      base.reorder(nil).where.not(region_country: nil)
          .group(:region_country).count
          .select { |_c, n| n >= CorpusEntry::MIN_SAMPLE_SIZE }
          .sort_by { |_c, n| -n }.first(MAX_PER_DIMENSION)
          .map do |code, _n|
            [ "Country: #{WorldRegions.name_for(code)}", base.where(region_country: code) ]
          end
    end

    # Segment breakdowns are only published for the types whose counts are
    # frequencies. prioritise is excluded here for the same reason it is handled
    # separately in the indexer — its counts are rank sums, and a segmented rank
    # sum is even easier to misread than a whole-Verto one.
    def countable(result)
      type = result[:type].to_s
      return {} unless CorpusIndexer::COUNT_TYPES.include?(type)

      result[:counts].each_with_object({}) { |(k, v), out| out[k.to_s] = v.to_i }
    end
  end
end
