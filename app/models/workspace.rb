class Workspace < ApplicationRecord
  has_many :users, dependent: :destroy
  has_many :agents, dependent: :destroy
  has_many :conversations, dependent: :destroy

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true
end
