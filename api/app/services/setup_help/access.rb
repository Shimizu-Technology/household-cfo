module SetupHelp
  class Access
    def self.participant!(household, user:, cohort_membership: nil, owner: false, request: nil)
      actor = User.lock.find_by(id: user&.id)
      membership = household.household_memberships.lock.find_by(user_id: actor&.id)
      allowed = actor&.invitation_accepted? && !actor.revoked? && membership&.role.in?(owner ? %w[owner] : %w[owner partner])
      raise Denied, "This account cannot review this household setup. Nothing changed." unless allowed
      ChallengePrivacy::PrivateFinanceAccess.authorize!(household, user: actor)
      if cohort_membership
        selected = Mia::EffectiveCohortResolver.new(user: actor, role: "participant", requested_cohort_id: cohort_membership.cohort_id).call
        unless selected&.id == cohort_membership.id && selected.created_at == cohort_membership.created_at
          raise Denied, "Choose your current coaching program before reviewing setup. Nothing changed."
        end
        enrollment = SavingsEnrollment.lock.find_by(user: actor, cohort: selected.cohort)
        if selected.cohort.savings_challenge_enabled || enrollment
          SavingsChallenge::AccessPolicy.new(household: household, user: actor, cohort: selected.cohort, enrollment: enrollment, lock: true).call!
        end
      elsif ChallengePrivacy::PrivateFinanceAccess.pilot_household?(household)
        raise Denied, "Choose your current coaching program before reviewing setup. Nothing changed."
      end
      if request
        unless request.household_id == household.id && request.requested_by_user_id == actor.id && request.cohort_id == cohort_membership&.cohort_id &&
          request.participant_membership_id == cohort_membership&.id && request.participant_membership_started_at == cohort_membership&.created_at
          raise Denied, "This setup request is no longer available for your account and program. Nothing changed."
        end
      end
      actor
    rescue ChallengePrivacy::PrivateFinanceAccess::Denied, SavingsChallenge::AccessPolicy::Unavailable, Mia::EffectiveCohortResolver::InvalidSelection
      raise Denied, "Choose your current coaching program before reviewing setup. Nothing changed."
    end

    def self.requester!(request)
      member = request.cohort&.cohort_memberships&.find_by(id: request.participant_membership_id)
      participant!(request.household, user: request.requested_by_user, cohort_membership: member, owner: true, request: request)
    end

    def self.staff!(request, user:, prepare: false, action: nil)
      actor = User.lock.find_by(id: user&.id)
      raise Denied, "This setup support request is unavailable." unless actor&.staff? && actor.invitation_accepted? && !actor.revoked?
      if request.cohort
        ChallengePrivacy::Access.staff!(request.cohort, actor)
      elsif !actor.admin? || ChallengePrivacy::PrivateFinanceAccess.pilot_household?(request.household)
        raise Denied, "This setup support request is unavailable."
      end
      requester!(request)
      mutation = prepare ? "prepare" : action
      if mutation && !permissions_for(request, actor).fetch(mutation.to_sym, false)
        raise Denied, "This account does not have permission for that support action."
      end
      actor
    rescue ChallengePrivacy::Access::Denied, ChallengePrivacy::PrivateFinanceAccess::Denied, SavingsChallenge::AccessPolicy::Unavailable, Mia::EffectiveCohortResolver::InvalidSelection
      raise Denied, "This setup support request is unavailable."
    end
    def self.permissions(request, user:)
      actor = staff!(request, user: user)
      permissions_for(request, actor)
    end

    def self.permissions_for(request, actor)
      independent = actor.id != request.requested_by_user_id
      return { triage: true, prepare: independent, decline: true } unless request.cohort
      role = CoachWorkspaceMembership.lock.find_by(coach_workspace_id: request.cohort.coach_workspace_id, user_id: actor.id)&.role
      mutation = role.in?(%w[owner editor reviewer])
      { triage: mutation, prepare: independent && actor.admin? && role.in?(%w[owner reviewer]), decline: mutation }
    end
    private_class_method :permissions_for
  end
end
