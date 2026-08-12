# One follow-up in an automation's drip sequence. delay_minutes anchors on
# the TRIGGER event, not the previous step. Compiles on save like its
# parent; a step without content simply never books (the enqueue sweep
# skips uncompiled steps).
class EmailAutomationStep < ApplicationRecord
  belongs_to :email_automation
  has_many :email_automation_runs, dependent: :nullify

  # A booked-but-unsent run must not survive its step's deletion as a
  # primary send (the nullify would re-point it at the automation's own
  # content). Sent runs keep their history, step reference nullified.
  # prepend: the association's own dependent-nullify callback registered
  # first and would empty the association before this ran.
  before_destroy :skip_queued_runs, prepend: true

  validates :delay_minutes, numericality: { greater_than_or_equal_to: 0 }
  validates :send_hour, numericality: { in: 0..23 }, allow_nil: true

  before_save :sanitize_design!
  before_save :sanitize_send_days!
  before_save :compile!

  scope :ordered, -> { order(:position, :id) }

  def document
    Comms::EmailDocument.coerce(design)
  end

  def warnings
    Comms::EmailDocument.warnings(document)
  end

  def sendable?
    subject.present? && compiled_html.present?
  end

  private

  def skip_queued_runs
    email_automation_runs.where(status: "queued")
                         .update_all(status: "skipped", updated_at: Time.current)
  end

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
