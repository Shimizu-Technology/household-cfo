module ChallengePrivacy
  class Access
    Denied = Class.new(ArgumentError)
    UNAVAILABLE = "This shared challenge record is unavailable"
    def self.participant!(household, actor, enrollment, active: false)
      actor = User.lock.find_by(id: actor&.id)
      membership = household.household_memberships.lock.find_by(user_id: actor&.id)
      # A counted enrollment belongs to a participant and a preview one to staff:
      # someone who changed role no longer reaches the other kind's records.
      unless actor&.household_seat_in?(household) && !actor.revoked? && membership&.role.in?(%w[owner partner]) && enrollment.household_id == household.id &&
          enrollment.user_id == actor.id && enrollment.preview? == actor.staff?
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
      raise Denied, UNAVAILABLE unless staff_allowed?(cohort, actor, export: export, lock: true)
      actor
    end

    # The same rule as `staff!`, as a question. The Admin side's section list asks
    # it, so it offers only what these reads would allow.
    def self.staff_allowed?(cohort, actor, export: false, lock: false)
      members = CoachWorkspaceMembership.where(coach_workspace_id: cohort.coach_workspace_id, user_id: actor&.id)
      member = lock ? members.lock.first : members.first
      memberships = cohort.cohort_memberships
      memberships = memberships.lock if lock
      program = cohort.created_by_user_id == actor&.id || memberships.exists?(user_id: actor&.id, role: %w[coach admin])
      allowed = actor&.staff? && !actor.revoked? && member && program
      allowed &&= member.role.in?(%w[owner reviewer]) if export
      allowed ? true : false
    end

    # The people list is operational metadata only: names, status, today's
    # check-in and open help requests. Private records still need a grant
    # addressed to the reader. Program coaches read it through `staff!`. A
    # platform administrator who is not on the program's team reads it through
    # this defined path instead, and the caller records each such read.
    # Returns :program or :platform_admin.
    def self.roster!(cohort, actor)
      staff!(cohort, actor)
      :program
    rescue Denied
      actor = User.lock.find_by(id: actor&.id)
      raise Denied, UNAVAILABLE unless actor&.admin? && !actor.revoked?

      :platform_admin
    end

    # Who may read a sealed sponsor report: the program's owner or reviewer, else a
    # platform administrator. Returns :program or :platform_admin; the caller
    # records each platform-administrator read.
    def self.export_reader!(cohort, actor)
      staff!(cohort, actor, export: true)
      :program
    rescue Denied
      actor = User.lock.find_by(id: actor&.id)
      raise Denied, UNAVAILABLE unless actor&.admin? && !actor.revoked?

      :platform_admin
    end

    def self.participant_current!(enrollment)
      participant!(enrollment.household, enrollment.user, enrollment)
      member = enrollment.cohort.cohort_memberships.lock.find_by(user_id: enrollment.user_id, role: "participant")
      unless member && member.id == enrollment.accepted_cohort_membership_id && member.created_at == enrollment.membership_started_at
        raise Denied, UNAVAILABLE
      end
    end
  end
end
