class EmailListContact < ApplicationRecord
  belongs_to :email_list

  normalizes :email, with: ->(e) { Comms.normalize_email(e) }

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
end
