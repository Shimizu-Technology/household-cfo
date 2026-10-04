class SavingsDebtVersion < ApplicationRecord
  include SavingsImmutable
  belongs_to :savings_debt_card
  belongs_to :savings_enrollment
  belongs_to :approved_by_user, class_name: "User"
  belongs_to :previous_version, class_name: "SavingsDebtVersion", optional: true
  belongs_to :source_tracked_account, optional: true
  belongs_to :source_account_identity_version, optional: true
  belongs_to :source_revision_approval, optional: true
  validates :approved_at, :digest, presence: true
  validates :version_number, numericality: { only_integer: true, greater_than: 0 }
  validate :approval_scope

  private

  def approval_scope
    errors.add(:base, "Approved debt terms must belong to this participant's card") unless savings_debt_card&.savings_enrollment_id == savings_enrollment_id && approved_by_user_id == savings_enrollment&.user_id
    errors.add(:terms, "must preserve reviewed exact values") unless SavingsChallenge::Debt::Terms.normalize(terms) == terms
    if previous_version
      errors.add(:previous_version, "must precede this card version") unless previous_version.savings_debt_card_id == savings_debt_card_id && version_number == previous_version.version_number + 1
      errors.add(:reason, "must explain the correction") if reason.blank?
    end
  rescue ArgumentError => error
    errors.add(:terms, error.message)
  end
end
