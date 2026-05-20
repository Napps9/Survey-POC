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

  # This Verto's own palette (the three user-set roles). Legacy Vertos with no
  # palette fall back to the Playverto default so they render unchanged.
  def brand_palette
    read_attribute(:brand_palette).presence || BrandPalette::DEFAULT
  end

  def resolved_brand_palette
    BrandPalette.resolve(brand_palette)
  end

  def archive!
    update!(deleted_at: Time.current)
  end

  def published?
    publish_token.present?
  end

  # A "responder" is anyone who answered at least one question (not just those
  # who submitted). Reads the preloaded :responses association in Ruby so the
  # dashboard's includes(:responses) avoids per-card queries.
  def responders
    responses.to_a.select do |r|
      r.answers.is_a?(Hash) && r.answers.values.any? { |a| a.is_a?(Hash) && a["value"].present? }
    end
  end

  def responders_count
    responders.size
  end

  # Of the responders, the percentage who completed (submitted) the Verto.
  # nil when there are no responders yet.
  def completion_rate
    rs = responders
    return nil if rs.empty?
    (rs.count { |r| r.status == "completed" } * 100.0 / rs.size).round
  end
end
