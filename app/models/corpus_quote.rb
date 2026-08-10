# One respondent's own words, redacted and cleared for citation.
#
# The body stored here is what a reader sees. Ask Verto references a quote by id —
# it never reproduces the text itself — and the server prints this record. A model
# that paraphrases a respondent therefore produces a broken reference rather than a
# plausible misquote, which is the only version of "verbatim" worth shipping.
#
# Everything that makes that safe happens before a row exists: QuoteRedactor strips
# contact details and place names, OpenTextThemer drops anything still identifying,
# the body is length-capped, and a reviewer reads them before the Verto is approved.
# `approved` is the last lever — one quote can be retired without re-indexing the
# question it illustrates.
class CorpusQuote < ApplicationRecord
  belongs_to :corpus_question

  # Long enough to be a real sentence, short enough that a quote can't become a
  # life story. A respondent who writes three paragraphs is far easier to identify
  # from them than from one line.
  MAX_LENGTH = 300

  validates :body, presence: true, length: { maximum: MAX_LENGTH }

  scope :approved, -> { where(approved: true) }
  scope :citable,  -> { approved.joins(corpus_question: :corpus_entry).merge(CorpusEntry.citable) }
end
