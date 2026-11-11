module ChallengePrivacy
  # Pilot enrollment never makes household financial records a staff workspace.
  # Selected staff reads have a separate, audited SharedReader path.
  class PrivateFinanceAccess
    Denied = Class.new(StandardError)

    # A staff member's preview enrollment does not make their own household a
    # participant's: only counted enrollments and participant seats do.
    def self.without_pilot_households(scope)
      participant_ids = CohortMembership.joins(:cohort).where(role: "participant", cohorts: { savings_challenge_enabled: true }).select(:user_id)
      scope.where.not(household_id: SavingsEnrollment.counted.select(:household_id))
        .where.not(household_id: HouseholdMembership.where(user_id: participant_ids).select(:household_id))
    end

    def self.pilot_household?(household)
      SavingsEnrollment.counted.where(household: household).exists? ||
        CohortMembership.joins(:cohort).where(user_id: household.household_memberships.select(:user_id), role: "participant",
          cohorts: { savings_challenge_enabled: true }).exists?
    end

    def self.authorize!(household, user:)
      return unless pilot_household?(household)
      actor = User.find_by(id: user&.id)
      membership = household.household_memberships.find_by(user_id: actor&.id)
      allowed = actor&.household_seat? && !actor.staff? && !actor.revoked? && membership&.role.in?(%w[owner partner])
      raise Denied, "Participant finances are private. Use an explicitly shared support record." unless allowed
      true
    end
  end
end
