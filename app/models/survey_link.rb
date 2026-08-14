# One named way of sending a Verto out: its own /play/:slug address, its own
# response tally, and its own overrides for the three things a respondent
# notices after they finish (results comparison, the Share button, the regions
# map).
#
# The overrides are three-state on purpose. nil — the default — means "follow
# the Verto", so a creator who changes the Verto's own setting later moves
# every link that never disagreed with it. true/false pin the answer for
# everyone arriving through this link, which is the whole point: send one
# cohort a link that shows them how everyone else answered, and another one
# that doesn't.
class SurveyLink < ApplicationRecord
  belongs_to :survey
  # nullify, not destroy: deleting a link must never delete the answers that
  # came in through it. They fall back to counting as the Verto's own.
  has_many :responses, dependent: :nullify

  # A cap, not a business rule — a send list this long is a sign something
  # else is wanted (partner groups), and it keeps the modal a modal.
  MAX_PER_SURVEY = 25
  MAX_NAME       = 60
  # How many `-2`, `-3`… suffixes to try before falling back to a random one.
  SLUG_SUFFIX_TRIES = 50

  before_validation :apply_defaults
  validates :name, presence: true, length: { maximum: MAX_NAME }
  validates :slug, presence: true
  # Covers other send links too, so there is no separate uniqueness validation
  # to disagree with it.
  validate  :slug_free_in_play_namespace

  scope :ordered, -> { order(:created_at, :id) }
  scope :active,  -> { where(active: true) }

  # The /play/:token segment for this link. Unlike Survey#public_link_key there
  # is no opaque fallback — the slug IS the address.
  def play_key = slug

  # ── Effective settings ────────────────────────────────────────────────────
  # Survey answers the same three questions (see Survey#compare_results?), so a
  # caller holding either object can ask without knowing which it has:
  #   (@survey_link || @survey).compare_results?
  def compare_results?
    show_results_comparison.nil? ? survey.compare_results? : show_results_comparison
  end

  def share_button?
    share_enabled.nil? ? survey.share_button? : share_enabled
  end

  def regions_map?
    regions_enabled.nil? ? survey.regions_map? : regions_enabled
  end

  # The Verto's own promise text is shared by every link — the setting that
  # differs per link is whether the comparison is offered at all.
  def compare_note_text = survey.compare_note_text

  # A slug nobody else in the /play/ namespace is using, derived from `desired`
  # (or from `fallback`, normally the link's name) and de-collided with a
  # numeric suffix. Returns something usable even from junk input: a link with
  # no reachable address would be worse than an unmemorable one.
  def self.mint_slug(desired, fallback: nil, excluding_id: nil)
    base = Survey.normalize_slug(desired.presence || fallback) ||
           SecureRandom.alphanumeric(10).downcase
    return base unless Survey.play_key_taken?(base, excluding_link_id: excluding_id)

    (2..SLUG_SUFFIX_TRIES).each do |n|
      candidate = "#{base.first(Survey::MAX_SLUG_LENGTH - n.to_s.length - 1)}-#{n}"
      return candidate unless Survey.play_key_taken?(candidate, excluding_link_id: excluding_id)
    end
    "#{base.first(Survey::MAX_SLUG_LENGTH - 7)}-#{SecureRandom.alphanumeric(6).downcase}"
  end

  private

  def apply_defaults
    self.name = name.to_s.strip.first(MAX_NAME).presence
    self.slug = Survey.normalize_slug(slug)
  end

  # The uniqueness validation above only sees other send links. This is the
  # rest of the namespace PlayerController#load_survey_and_share resolves —
  # without it a link could shadow a live Verto's own address.
  def slug_free_in_play_namespace
    return if slug.blank?
    return unless Survey.play_key_taken?(slug, excluding_link_id: id)

    errors.add(:slug, :taken)
  end
end
