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

  # Image-block uploads (media picker) — bytes live here, short blob paths
  # live in the design json, same shape as Survey#card_images.
  has_many_attached :images

  validates :title, presence: true
  validates :status, inclusion: { in: STATUSES }

  before_save :sanitize_design!

  scope :recent, -> { order(created_at: :desc) }

  STATUSES.each do |s|
    define_method("#{s}?") { status == s }
  end

  def editable?
    EDITABLE_STATUSES.include?(status)
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

  private

  def sanitize_design!
    self.design = Comms::EmailDocument.sanitize(design) if will_save_change_to_design?
  end
end
