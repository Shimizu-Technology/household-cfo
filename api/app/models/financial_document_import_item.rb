class FinancialDocumentImportItem < ApplicationRecord
  TARGET_TYPES = %w[income_source expense_item account debt goal profile_note].freeze
  CONFIDENCE_LEVELS = %w[high medium low].freeze

  belongs_to :financial_document_import, inverse_of: :items
  belongs_to :applied_by_user, class_name: "User", optional: true
  belongs_to :applied_record, polymorphic: true, optional: true

  validates :target_type, inclusion: { in: TARGET_TYPES }
  validates :label, presence: true, length: { maximum: 120 }
  validates :amount_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :balance_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :payment_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :cadence, inclusion: { in: IncomeSource::CADENCES }, allow_blank: true
  validates :source_type, inclusion: { in: IncomeSource::SOURCE_TYPES }, allow_blank: true
  validates :stack_key, inclusion: { in: ExpenseItem::STACK_KEYS }, allow_blank: true
  validates :account_type, inclusion: { in: Account::ACCOUNT_TYPES }, allow_blank: true
  validates :debt_type, inclusion: { in: Debt::DEBT_TYPES }, allow_blank: true
  validates :confidence, inclusion: { in: CONFIDENCE_LEVELS }, allow_blank: true
  validates :evidence, length: { maximum: 1000 }, allow_blank: true
  validate :required_financial_value_present

  scope :apply_candidates, -> { where(selected: true, ignored: false, applied_at: nil) }

  def applied?
    applied_at.present?
  end

  private

  def required_financial_value_present
    case target_type
    when "income_source", "expense_item", "goal"
      errors.add(:amount_cents, "is required") if amount_cents.blank?
    when "account"
      errors.add(:balance_cents, "is required") if balance_cents.blank?
    when "debt"
      errors.add(:balance_cents, "is required") if balance_cents.blank? && payment_cents.blank?
    end
  end
end
