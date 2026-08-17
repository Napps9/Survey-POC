# One open/close cycle of a Verto being run again to measure change — the
# owner explicitly starts and stops these; a wave is never derived from
# timestamps (see Survey#start_next_wave! for why that's impossible with
# published_at/unpublished_at alone).
class SurveyWave < ApplicationRecord
  belongs_to :survey
  # A response's wave is set once at write time and never changes — closing
  # or even destroying a wave record must not touch the responses already
  # attributed to it, only detach the label.
  has_many :responses, dependent: :nullify

  validates :position, presence: true, uniqueness: { scope: :survey_id }
  validates :opened_at, presence: true

  def open?
    closed_at.nil?
  end

  # "Wave 2" when the owner never bothered naming it — a position-based
  # fallback that's still meaningful sorted, unlike a bare "Untitled".
  def display_label
    label.presence || "Wave #{position}"
  end
end
