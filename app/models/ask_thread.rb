# One Ask Verto conversation.
#
# Scoped to the organisation rather than the user: an answer a colleague already
# asked for is worth finding, and the corpus it draws on is the same for everyone.
class AskThread < ApplicationRecord
  belongs_to :organisation
  belongs_to :user

  has_many :ask_messages, -> { order(:created_at) }, dependent: :destroy

  scope :recent, -> { order(updated_at: :desc) }

  # How many threads one account keeps. A conversation list is a navigation aid,
  # not an archive, and an unbounded list on the rail is a slow page for everyone.
  MAX_PER_ORGANISATION = 50

  # The rail's label. Falls back to the opening question, trimmed, because a thread
  # named "Untitled" is no easier to find than an unnamed one.
  def display_title
    title.presence || ask_messages.find_by(role: "user")&.text&.truncate(60) || "New thread"
  end

  # The messages Claude is given. Bounded, and only the prose — a previous turn's
  # markers are stripped (see AskMessage#prompt_text), because their numbers were
  # minted per-turn and would re-enter as valid-looking citations of the wrong
  # sources. A turn that stripping leaves empty (an answer that was only markers)
  # is dropped entirely: the API rejects an empty content block, and consecutive
  # same-role turns are legal — they're combined server-side.
  def prompt_messages(limit: 20)
    ask_messages.last(limit)
                .map { |m| { role: m.role, content: m.prompt_text } }
                .reject { |m| m[:content].blank? }
  end

  # Trim the oldest threads past the cap. Called after a thread is created, so the
  # list stays bounded without a sweep job.
  def self.prune!(organisation)
    ids = where(organisation_id: organisation.id).recent.offset(MAX_PER_ORGANISATION).pluck(:id)
    where(id: ids).destroy_all if ids.any?
  end
end
