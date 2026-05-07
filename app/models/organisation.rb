class Organisation < ApplicationRecord
  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships
  has_many :surveys, dependent: :destroy
end
