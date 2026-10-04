module SavingsImmutable
  extend ActiveSupport::Concern

  included do
    before_update :reject_savings_history_mutation
    before_destroy :reject_savings_history_mutation
  end

  private

  def reject_savings_history_mutation
    errors.add(:base, "Approved savings history is immutable")
    throw :abort
  end
end
