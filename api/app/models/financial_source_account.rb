class FinancialSourceAccount < ApplicationRecord
  BASES = %w[asset liability unknown].freeze
  belongs_to :household
  belongs_to :financial_extraction_revision
  has_many :financial_source_events
  has_one :financial_source_evidence
  validates :source_key, presence: true
  validates :account_basis, inclusion: { in: BASES }
  validate :household_scope

  def readonly?
    persisted?
  end

  private

  def household_scope
    errors.add(:financial_extraction_revision, "must belong to the account household") if financial_extraction_revision && financial_extraction_revision.household_id != household_id
  end
end
