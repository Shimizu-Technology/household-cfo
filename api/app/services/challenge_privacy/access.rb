module ChallengePrivacy
  class Access
    Denied = Class.new(ArgumentError)
    def self.participant!(household, actor, enrollment, active: false)
      actor = User.lock.find_by(id: actor&.id)
      membership = household.household_memberships.lock.find_by(user_id: actor&.id)
      unless actor&.participant? && !actor.revoked? && membership&.role.in?(%w[owner partner]) && enrollment.household_id == household.id && enrollment.user_id == actor.id
        raise Denied, "This private challenge record is unavailable"
      end
      if active
        SavingsChallenge::AccessPolicy.new(household: household, user: actor, cohort: enrollment.cohort, enrollment: enrollment, lock: true).call!
      end
      actor
    end

    # Require explicit workspace AND program membership; platform administrator
    # permissions never substitute for participant-authorized private access.
    def self.staff!(enrollment_or_cohort, actor, export: false)
      cohort = enrollment_or_cohort.is_a?(Cohort) ? enrollment_or_cohort : enrollment_or_cohort.cohort
      actor = User.lock.find_by(id: actor&.id)
      member = CoachWorkspaceMembership.lock.find_by(coach_workspace_id: cohort.coach_workspace_id, user_id: actor&.id)
      program = cohort.created_by_user_id == actor&.id || cohort.cohort_memberships.lock.exists?(user_id: actor&.id, role: %w[coach admin])
      allowed = actor&.staff? && !actor.revoked? && member && program
      allowed &&= member.role.in?(%w[owner reviewer]) if export
      raise Denied, "This shared challenge record is unavailable" unless allowed
      actor
    end

    def self.participant_current!(enrollment)
      participant!(enrollment.household, enrollment.user, enrollment)
      member = enrollment.cohort.cohort_memberships.lock.find_by(user_id: enrollment.user_id, role: "participant")
      unless member && member.id == enrollment.accepted_cohort_membership_id && member.created_at == enrollment.membership_started_at
        raise Denied, "This shared challenge record is unavailable"
      end
    end
  end
end
