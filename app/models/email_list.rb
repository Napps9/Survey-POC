# An imported contact list (pasted or CSV) for Comms campaigns.
# contacts_count is maintained by the import path (imports use insert_all,
# which no counter cache sees).
class EmailList < ApplicationRecord
  belongs_to :created_by, class_name: "User", optional: true
  has_many :email_list_contacts, dependent: :delete_all

  validates :name, presence: true

  scope :recent, -> { order(created_at: :desc) }

  def recount!
    update!(contacts_count: email_list_contacts.count)
  end
end
