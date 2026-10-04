module ChallengePrivacyScoped
  extend ActiveSupport::Concern
  included do
    belongs_to :household
    belongs_to :savings_enrollment
    belongs_to :participant_user, class_name: "User"
    validate do
      unless savings_enrollment && household_id == savings_enrollment.household_id && participant_user_id == savings_enrollment.user_id
        errors.add(:base, "Privacy record belongs to a different participant")
      end
    end
  end
end
