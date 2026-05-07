class Membership < ApplicationRecord
  belongs_to :user
  belongs_to :organisation
  enum :role, { member: "member", admin: "admin" }
end
