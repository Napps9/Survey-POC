# One send to one respondent about one Verto. See the migration for why it is
# a row rather than a fire-and-forget mailer call.
class PlayerNotification < ApplicationRecord
  belongs_to :player
  belongs_to :survey
  belongs_to :organisation

  KINDS = %w[impact follow_up].freeze
  validates :kind, inclusion: { in: KINDS }

  TOKEN_BYTES = 32

  # Claim the right to tell this person this thing, exactly once.
  #
  # Returns the record on the FIRST claim and nil on every repeat, so the
  # caller mails only when it actually won — the unique index is the lock, so
  # two jobs racing on the same person cannot both send. Deliberately not
  # find_or_create_by!: that returns the existing row too, and a caller would
  # have to remember to ask whether it was new.
  def self.claim(player:, survey:, kind:)
    create!(player: player, survey: survey, organisation_id: survey.organisation_id,
            kind: kind, token: SecureRandom.urlsafe_base64(TOKEN_BYTES))
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    nil
  end

  def sent! = update_column(:sent_at, Time.current)
end
