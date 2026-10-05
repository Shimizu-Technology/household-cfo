class SavingsDebtDraft < ApplicationRecord
  belongs_to :savings_debt_card
  belongs_to :savings_enrollment
  belongs_to :created_by_user, class_name: "User"
  belongs_to :base_version, class_name: "SavingsDebtVersion", optional: true
  belongs_to :approved_version, class_name: "SavingsDebtVersion", optional: true
  belongs_to :source_tracked_account, optional: true
  belongs_to :household_debt, class_name: "Debt", optional: true
  belongs_to :source_account_identity_version, optional: true
  belongs_to :source_revision_approval, optional: true
  validates :status, inclusion: { in: %w[pending approved] }
  validate :review_scope

  private

  def review_scope
    errors.add(:base, "Debt draft must belong to this participant's card") unless savings_debt_card&.savings_enrollment_id == savings_enrollment_id && created_by_user_id == savings_enrollment&.user_id
    errors.add(:terms, "must preserve reviewed exact values") unless SavingsChallenge::Debt::Terms.normalize(terms) == terms
  rescue ArgumentError => error
    errors.add(:terms, error.message)
  end
end
