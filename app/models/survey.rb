class Survey < ApplicationRecord
  belongs_to :organisation
  has_many :responses, dependent: :destroy
  has_many :survey_shares, dependent: :destroy

  scope :recent,   -> { order(updated_at: :desc) }
  scope :kept,     -> { where(deleted_at: nil) }
  scope :archived, -> { where.not(deleted_at: nil) }

  def deleted?
    deleted_at.present?
  end

  def archive!
    update!(deleted_at: Time.current)
  end

  def published?
    publish_token.present?
  end
end
