# One citable question from an approved Verto, with its distribution already
# aggregated.
#
# This is what Ask Verto's tools read. `responses` is never touched at query time,
# which is the whole point: the aggregation happened once, at index time, inside the
# owning account's own data, and what crossed the boundary was counts.
#
# The id is the citation. A tool returns it, the model writes it back inside a
# [[c:<id>]] marker, and AskVertoChat resolves the marker against the ids that were
# actually returned. A number the model invented has no row behind it and never
# reaches the reader.
class CorpusQuestion < ApplicationRecord
  belongs_to :corpus_entry
  has_many :corpus_quotes, dependent: :destroy

  # Only citable through a citable entry — the join is the gate, and it is the only
  # way anything reads these rows.
  scope :citable, -> { joins(:corpus_entry).merge(CorpusEntry.citable) }

  delegate :survey, :organisation, to: :corpus_entry

  # Options a respondent could pick, in the order the card offered them. Stored so
  # a distribution can be read even when an option got zero picks — an option
  # nobody chose is a finding, and a bare {label => count} hash loses it.
  def option_labels = Array(options).map(&:to_s)

  # The distribution as ordered pairs, largest first, with each option's share of
  # the answers to THIS question. Percentages are computed here rather than stored
  # so there is one rounding rule for the whole product.
  def ranked_options
    counts = distribution.is_a?(Hash) ? distribution.except("avg") : {}
    total  = counts.values.sum { |v| v.to_i }
    return [] if total.zero?

    counts.sort_by { |_, v| -v.to_i }.map do |label, count|
      { label: label.to_s, count: count.to_i, percent: (count.to_i * 100.0 / total).round(1) }
    end
  end

  def average
    distribution["avg"] if distribution.is_a?(Hash)
  end

  def open_text? = card_type == "open_ended"

  def quotes = corpus_quotes.where(approved: true)
end
