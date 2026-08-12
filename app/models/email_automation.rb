# An event-triggered email: when a VertoNow-native event fires for a subject
# (a user, or an org's members), a run is enqueued after delay_minutes,
# optionally rolled to a send window (send_hour / send_days, interpreted in
# COMMS_TIME_ZONE). Compiles on save — an enabled automation always sends
# its latest saved content; the runs ledger's unique idempotency keys are
# what stop re-sends, not frozen copies.
class EmailAutomation < ApplicationRecord
  TRIGGER_TYPES = %w[user_signed_up user_inactive first_verto_published first_response_received].freeze

  belongs_to :created_by, class_name: "User", optional: true
  has_many :email_automation_runs, dependent: :delete_all
  has_many_attached :images

  validates :name, presence: true
  validates :trigger_type, inclusion: { in: TRIGGER_TYPES }
  validates :delay_minutes, numericality: { greater_than_or_equal_to: 0 }
  validates :send_hour, numericality: { in: 0..23 }, allow_nil: true

  before_save :sanitize_design!
  before_save :sanitize_send_days!
  before_save :compile!

  scope :recent, -> { order(created_at: :desc) }

  def document
    Comms::EmailDocument.coerce(design)
  end

  def warnings
    Comms::EmailDocument.warnings(document)
  end

  # Enabling is refused until there is something sendable — the switch in
  # the UI reports the reason.
  def enableable?
    subject.present? && compiled_html.present? && warnings.empty?
  end

  private

  def sanitize_design!
    self.design = Comms::EmailDocument.sanitize(design) if will_save_change_to_design?
  end

  def sanitize_send_days!
    return unless will_save_change_to_send_days?

    self.send_days = Array(send_days).map(&:to_i).select { |d| (1..7).cover?(d) }.uniq.sort
  end

  def compile!
    return unless will_save_change_to_design? || will_save_change_to_subject? ||
                  will_save_change_to_preheader? || compiled_html.nil?

    doc = Comms::EmailDocument.coerce(design)
    if doc["blocks"].any?
      self.compiled_html = Comms::CampaignFreezer.absolutize(
        Comms::EmailRenderer.render_html(doc, preheader: preheader)
      )
      self.compiled_text = Comms::EmailRenderer.render_text(doc)
    else
      self.compiled_html = nil
      self.compiled_text = nil
    end
  end
end
