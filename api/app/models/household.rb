class Household < ApplicationRecord
  belongs_to :created_by_user, class_name: "User"

  has_many :household_memberships, dependent: :destroy
  has_many :users, through: :household_memberships
  has_one :household_profile, dependent: :destroy
  has_many :historical_income_sources, class_name: "IncomeSource"
  has_many :income_sources, -> { current_picture }, dependent: :destroy
  has_many :historical_expense_items, class_name: "ExpenseItem"
  has_many :expense_items, -> { current_picture }, dependent: :destroy
  has_many :historical_debts, class_name: "Debt"
  has_many :debts, -> { current_picture }, dependent: :destroy
  has_many :historical_accounts, class_name: "Account"
  has_many :accounts, -> { current_picture }, dependent: :destroy
  has_many :historical_goals, class_name: "Goal"
  has_many :goals, -> { current_picture }, dependent: :destroy
  has_many :chat_sessions, dependent: :destroy
  has_many :historical_transaction_drafts, class_name: "TransactionDraft"
  has_many :transaction_drafts, -> { current_picture }, dependent: :destroy
  has_many :historical_merchant_category_rules, class_name: "MerchantCategoryRule"
  has_many :merchant_category_rules, -> { current_picture }, dependent: :destroy
  has_many :historical_household_transactions, class_name: "HouseholdTransaction"
  has_many :household_transactions, -> { current_picture }, dependent: :destroy
  has_many :historical_budget_years, class_name: "BudgetYear"
  has_many :budget_years, -> { current_picture }, dependent: :destroy
  has_many :historical_budget_categories, class_name: "BudgetCategory"
  has_many :budget_categories, -> { current_picture }, dependent: :destroy
  has_many :financial_document_imports, dependent: :destroy
  has_many :historical_mia_action_drafts, class_name: "MiaActionDraft"
  has_many :mia_action_drafts, -> { current_picture }, dependent: :destroy
  has_many :mia_action_draft_applications, dependent: :destroy
  has_many :household_operation_executions, dependent: :destroy
  has_many :household_audit_events, dependent: :destroy
  has_many :household_memories, dependent: :destroy
  has_many :plaid_items, dependent: :destroy
  has_many :plaid_transactions, through: :plaid_items
  has_many :pilot_feedback_reports, dependent: :destroy

  has_many :financial_restart_reviews, dependent: :destroy

  validates :name, presence: true, length: { maximum: 120 }
  validates :primary_goal, length: { maximum: 500 }, allow_blank: true

  after_create :ensure_profile

  def ensure_profile
    household_profile || create_household_profile!
  end
end
