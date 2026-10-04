# Raw descriptions, merchant labels and extracted evidence can be erased without
# changing the immutable cents, dates, classification and revision lineage.
class FinancialSourceEvidence < ApplicationRecord
  belongs_to :household
  belongs_to :financial_source_account, optional: true
  belongs_to :financial_source_event, optional: true
  validate :subject_scope

  private

  def subject_scope
    subjects = [ financial_source_account, financial_source_event ].compact
    errors.add(:base, "Evidence requires exactly one source subject") unless subjects.one?
    errors.add(:base, "Evidence must belong to its source household") if subjects.any? { |subject| subject.household_id != household_id }
  end
end
