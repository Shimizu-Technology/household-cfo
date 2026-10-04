class FinancialSourceEvent < ApplicationRecord
  KINDS = %w[posted informational unresolved].freeze
  TYPES = %w[purchase fee refund income transfer debt_payment cash_withdrawal interest adjustment unknown].freeze
  belongs_to :household
  belongs_to :financial_extraction_revision
  belongs_to :financial_source_account
  has_one :financial_source_evidence
  validates :row_identity, presence: true
  validates :row_kind, inclusion: { in: KINDS }
  validates :event_type, inclusion: { in: TYPES }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :signed_amount_cents, numericality: { only_integer: true }, allow_nil: true
  validates :expense_amount_cents, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :household_scope

  def readonly?
    persisted?
  end

  def expense_projection_eligible?
    row_kind == "posted" && event_type.in?(%w[purchase fee interest]) && posted_on.present? && signed_amount_cents.to_i.negative? && expense_amount_cents.to_i.positive? && limitations.empty?
  end

  private

  def household_scope
    errors.add(:financial_extraction_revision, "must belong to the event household") if financial_extraction_revision && financial_extraction_revision.household_id != household_id
    errors.add(:financial_source_account, "must belong to the event revision") if financial_source_account && (financial_source_account.household_id != household_id || financial_source_account.financial_extraction_revision_id != financial_extraction_revision_id)
  end
end
