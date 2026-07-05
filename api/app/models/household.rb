class Household < ApplicationRecord
  belongs_to :created_by_user, class_name: "User"

  has_many :household_memberships, dependent: :destroy
  has_many :users, through: :household_memberships
  has_one :household_profile, dependent: :destroy
  has_many :income_sources, dependent: :destroy
  has_many :expense_items, dependent: :destroy
  has_many :debts, dependent: :destroy
  has_many :accounts, dependent: :destroy
  has_many :goals, dependent: :destroy
  has_many :chat_sessions, dependent: :destroy
  has_many :transaction_drafts, dependent: :destroy
  has_many :household_transactions, dependent: :destroy
  has_many :budget_years, dependent: :destroy
  has_many :budget_categories, dependent: :destroy
  has_many :financial_document_imports, dependent: :destroy

  validates :name, presence: true, length: { maximum: 120 }
  validates :primary_goal, length: { maximum: 500 }, allow_blank: true

  after_create :ensure_profile

  def ensure_profile
    household_profile || create_household_profile!
  end
end
