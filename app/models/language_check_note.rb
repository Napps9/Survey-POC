# A comment on one (card, language) line. See the migration for why it is not
# hung off the LanguageCheck row.
#
# `body` is bounded and screened rather than trusted: anyone holding a review
# link can write here without an account, which is the point of the link, so
# the text is treated exactly like other respondent-supplied free text — length
# capped, and never rendered as anything but plain text.
class LanguageCheckNote < ApplicationRecord
  belongs_to :survey
  belongs_to :author_user, class_name: "User", optional: true
  belongs_to :language_check_link, optional: true

  MAX_BODY = 2_000
  MAX_NAME = 60

  validates :cid, :locale, presence: true
  validates :body, presence: true, length: { maximum: MAX_BODY }

  scope :open_notes, -> { where(resolved_at: nil) }

  # Notes for a Verto grouped by line, oldest first within a line — a line's
  # notes are a short conversation, read top to bottom.
  def self.index_for(survey)
    where(survey_id: survey.id).order(:created_at).group_by { |n| [ n.cid, n.locale ] }
  end

  def author_label
    author_user&.name.presence || author_name.presence || I18n.t("language_check.anonymous_reviewer")
  end
end
