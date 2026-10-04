module SavingsDailyRecord
  extend ActiveSupport::Concern
  included do
    belongs_to :savings_enrollment
    validate :daily_participant_scope
  end

  def household
    savings_enrollment.household
  end

  private

  def daily_participant_scope
    if respond_to?(:approved_by_user_id)
      errors.add(:approved_by_user, "must be the enrolled participant") unless approved_by_user_id == savings_enrollment&.user_id
    elsif respond_to?(:created_by_user_id)
      errors.add(:created_by_user, "must be the enrolled participant") unless created_by_user_id == savings_enrollment&.user_id
    end
  end
end
