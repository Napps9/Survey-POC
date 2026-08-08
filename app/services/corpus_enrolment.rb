# Turns both Ask Verto consent keys in one step, for data VertoNow imports on a
# partner's behalf rather than data a customer offers through the editor.
#
# ── Why this is allowed to exist ───────────────────────────────────────────
# The two-key gate is the product's credibility, and nothing that bypasses it
# should be easy to reach for. This is the narrow case where one actor is
# legitimately both keys: VertoNow has the dataset, the agreement to use it, and
# the staff role that would approve it anyway. Making that a scripted step with
# an audit trail is better than a person clicking Approve on a queue of Vertos
# they just imported themselves.
#
# ── What it will not do ────────────────────────────────────────────────────
# It refuses to auto-approve anything the automated checks would have BLOCKED.
# A human reviewer can look at a failing check and decide anyway; an import
# cannot, because there is nobody reading. So a Verto below the sample floor —
# or one with no citable questions at all — is imported, offered, and left in
# the queue for a person. That is what makes "pre-approved" safe to offer: the
# floor still holds.
#
# Warnings are different from blocks. "3 open-text questions — quotes need a
# read" is a warning, and this reports it rather than stopping: the quotes are
# already redacted and identifiability-checked before they exist, and a warning
# that halted every import would just be a block wearing a different label.
class CorpusEnrolment
  Result = Struct.new(:entry, :approved, :blocked_by, :warnings, :questions, keyword_init: true) do
    def approved? = approved
    def blocked?  = !approved
  end

  # `reviewer` is recorded as the approver, so an audit of "who let this in"
  # names the import and the person who ran it rather than a bare timestamp.
  def initialize(survey, user:, reviewer:)
    @survey   = survey
    @user     = user
    @reviewer = reviewer
  end

  # Offers the Verto, approves it when the checks allow, and indexes it.
  # Returns a Result — never raises for a blocked Verto, because "this one needs
  # a human" is an ordinary outcome of importing several at once.
  def call(index: true)
    # The same population the indexer will count: everyone who answered
    # something. Checking the sample floor against finishers and then indexing
    # answerers would fail a Verto for a sample it does not actually use.
    answered = CorpusIndexer.countable_responses(@survey).count
    checks   = CorpusChecks.run(@survey, completed_count: answered)
    blocking  = CorpusChecks.blocking(checks)

    entry = CorpusEntry.for(@survey)
    entry.save! unless entry.persisted?
    entry.opt_in!(@user)
    entry.update!(check_results: { "checks" => checks.map(&:to_h) })

    if blocking.any?
      # Offered but not approved: it lands in the staff queue with the reason
      # already attached, which is exactly where a person can act on it.
      return Result.new(entry: entry, approved: false,
                        blocked_by: blocking.map(&:label),
                        warnings: warnings(checks), questions: 0)
    end

    entry.approve!(@reviewer)
    CorpusIndexer.new(entry).call if index

    Result.new(entry: entry.reload, approved: true, blocked_by: [],
               warnings: warnings(checks), questions: entry.corpus_questions.count)
  end

  private

  def warnings(checks)
    checks.select { |check| check.status == :warn }.map(&:label)
  end
end
