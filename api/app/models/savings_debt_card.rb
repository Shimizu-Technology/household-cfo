class SavingsDebtCard < ApplicationRecord
  belongs_to :savings_enrollment
  belongs_to :household
  belongs_to :user
  belongs_to :current_version, class_name: "SavingsDebtVersion", optional: true
  belongs_to :source_tracked_account, optional: true
  belongs_to :household_debt, class_name: "Debt", optional: true
  has_many :savings_debt_drafts, dependent: :restrict_with_exception
  has_many :savings_debt_versions, dependent: :restrict_with_exception
  validate :participant_scope

  private

  def participant_scope
    errors.add(:base, "Card identity must belong to its participant enrollment") unless savings_enrollment && savings_enrollment.household_id == household_id && savings_enrollment.user_id == user_id
    errors.add(:household_debt, "must be this household's credit card") if household_debt && (household_debt.household_id != household_id || household_debt.debt_type != "credit_card")
    errors.add(:current_version, "must belong to this card") if current_version && current_version.savings_debt_card_id != id
    errors.add(:source_tracked_account, "must be this household's liability") if source_tracked_account && (source_tracked_account.household_id != household_id || source_tracked_account.account_basis != "liability")
  end
end
