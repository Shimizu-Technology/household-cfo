class FinancialExtractionRevision < ApplicationRecord
  belongs_to :household
  belongs_to :financial_document_import, optional: true
  belongs_to :financial_document_import_attempt, optional: true
  has_many :financial_source_accounts
  has_many :financial_source_events

  validates :contract_version, :payload_digest, :source_document_identity, presence: true
  validates :revision_number, numericality: { only_integer: true, greater_than: 0 }
  validate :household_scope

  def readonly?
    persisted?
  end

  private

  def household_scope
    errors.add(:financial_document_import, "must belong to the revision household") if financial_document_import && financial_document_import.household_id != household_id
    errors.add(:financial_document_import_attempt, "must belong to the revision import") if financial_document_import_attempt && financial_document_import_attempt.financial_document_import_id != financial_document_import_id
  end
end
