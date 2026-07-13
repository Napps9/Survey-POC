class PartnershipVerto < ApplicationRecord
  belongs_to :partnership
  belongs_to :survey
  has_many :survey_shares, dependent: :destroy
end
