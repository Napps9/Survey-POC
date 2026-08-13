# A Comms email campaign: the block document being authored, who it goes to,
# and where it is in its life. Lifecycle (ported from Temple):
#
#   draft ──schedule──▶ scheduled ──due──▶ sending ──▶ sent
#     │◀──cancel schedule──┘                  ├──▶ failed
#     └──send now──▶ sending                  └──▶ cancelled (stopped mid-send)
#
# The content columns stay editable only in draft/scheduled; once a send is
# approved, what goes out is the frozen compiled_html/compiled_text +
# scheduled_snapshot, never the live row. Status moves through the bang
# methods below only — the controller's autosave cannot mass-assign it.
class EmailCampaign < ApplicationRecord
  STATUSES = %w[draft scheduled sending sent failed cancelled].freeze
  EDITABLE_STATUSES = %w[draft scheduled].freeze

  belongs_to :created_by, class_name: "User", optional: true

  has_many :email_campaign_recipients, dependent: :delete_all
  has_many :email_campaign_links, dependent: :delete_all
  has_many :email_events, dependent: :delete_all

  # Image-block uploads (media picker) — bytes live here, short blob paths
  # live in the design json, same shape as Survey#card_images.
  has_many_attached :images

  validates :title, presence: true
  validates :status, inclusion: { in: STATUSES }

  before_save :sanitize_design!
  before_save :sanitize_subject_variants!

  scope :recent, -> { order(created_at: :desc) }

  STATUSES.each do |s|
    define_method("#{s}?") { status == s }
  end

  def editable?
    EDITABLE_STATUSES.include?(status)
  end

  # Written by Comms::GenerateNewsletterJob rather than by hand, which is why
  # it still has a Projects placeholder in it.
  def newsletter?
    newsletter_week.present?
  end

  # Mirrors Survey#editing_locked? — every mutation endpoint 423s on it.
  def editing_locked?
    !editable?
  end

  def document
    Comms::EmailDocument.coerce(design)
  end

  def warnings
    Comms::EmailDocument.warnings(document)
  end

  # Advisory notes on the inbox row — never blocking, unlike `warnings`.
  def subject_review
    Comms::SubjectLine.review(subject: subject, preheader: preheader)
  end

  private

  def sanitize_design!
    self.design = Comms::EmailDocument.sanitize(design) if will_save_change_to_design?
  end

  # Up to three extra subjects (variant 0 is the subject itself) — the A/B
  # split is decided at recipient snapshot, deterministically.
  def sanitize_subject_variants!
    return unless will_save_change_to_subject_variants?

    self.subject_variants = Array(subject_variants).map { |v| v.to_s.strip }.reject(&:blank?).first(3)
  end
end
