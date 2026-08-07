# One turn in an Ask Verto conversation.
#
# `citations` is a SNAPSHOT, not a join. It records what was cited when the answer
# was given: the numbered marker, the corpus_question it resolved to, and enough of
# the source's description to render the answer again without re-reading the corpus.
#
# That is deliberate. If a Verto is withdrawn tomorrow, this answer must still read
# as it did — a report already quotes it — while no NEW answer may cite that Verto.
# A live join would rewrite the past to match the present, which is the opposite of
# what a citation is for. `stale_sources` is how the UI tells the reader when a
# source has since left the corpus.
class AskMessage < ApplicationRecord
  belongs_to :ask_thread

  ROLES = %w[user assistant].freeze
  validates :role, inclusion: { in: ROLES }

  def user?      = role == "user"
  def assistant? = role == "assistant"

  def citation_list = Array(citations)

  # Sources cited here that are no longer citable — withdrawn by their creator, or
  # un-approved since. Shown as a note on the old answer rather than hidden: a
  # reader who is about to quote a figure deserves to know its source has been
  # pulled.
  def stale_sources
    ids = citation_list.filter_map { |c| c["corpus_question_id"] }
    return [] if ids.empty?

    live = CorpusQuestion.citable.where(id: ids).pluck(:id).to_set
    citation_list.reject { |c| live.include?(c["corpus_question_id"]) }
  end
end
