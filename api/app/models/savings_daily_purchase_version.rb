class SavingsDailyPurchaseVersion < ApplicationRecord
  include SavingsDailyRecord
  include SavingsImmutable
  belongs_to :savings_daily_purchase
  belongs_to :approved_by_user, class_name: "User"
  belongs_to :previous_version, class_name: "SavingsDailyPurchaseVersion", optional: true
  validates :approved_at, presence: true
  validates :version_number, numericality: { only_integer: true, greater_than: 0 }
  validates :reason, length: { maximum: 500 }
  belongs_to :household_transaction
  validates :amount_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 2_147_483_647 }
  validates :disposition, inclusion: { in: %w[purchase void] }
  validates :merchant, presence: true, length: { maximum: 120 }
  validates :link_kind, inclusion: { in: %w[manual_new existing_transaction] }
  validate :financial_scope

  def financial_scope
    errors.add(:household_transaction, "must belong to this household") unless household_transaction&.household_id == savings_enrollment&.household_id
    errors.add(:purchased_on, "must be an elapsed challenge date") unless purchased_on && savings_enrollment && (savings_enrollment.starts_on..[ savings_enrollment.ends_on, savings_enrollment.local_today ].min).cover?(purchased_on)
    errors.add(:amount_cents, "must be exact integer cents") unless amount_cents_before_type_cast.instance_of?(Integer)
    if disposition == "void"
      valid = previous_version && previous_version.disposition == "purchase" && link_kind == "manual_new" && previous_version.link_kind == "manual_new" &&
        amount_cents == 0 && splits == [] && household_transaction_id == previous_version.household_transaction_id && household_transaction&.status == "ignored" && household_transaction&.financial_source_event_id.nil?
      errors.add(:disposition, "must explicitly void a participant-owned manual purchase") unless valid
    else
      expected = splits.map { |part| [ part.fetch("budget_category_id"), part.fetch("amount_cents") ] }.sort
      valid = amount_cents.positive? && household_transaction&.total_amount_cents == amount_cents && household_transaction&.merchant == merchant &&
        household_transaction&.status.in?(%w[confirmed reconciled]) && household_transaction.transaction_splits.pluck(:budget_category_id, :amount_cents).sort == expected
      errors.add(:household_transaction, "must match the exact canonical financial facts") unless valid
    end
  end
end
