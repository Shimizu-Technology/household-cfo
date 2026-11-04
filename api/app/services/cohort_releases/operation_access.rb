module CohortReleases
  # Additive deployed handlers never expand an older sealed cohort's authority.
  class OperationAccess
    def self.require!(household:, user:, key:, cohort: nil, membership: nil)
      actor = user && User.find_by(id: user.id)
      writable = actor && household.household_memberships.find_by(user_id: actor.id)&.role.in?(%w[owner partner])
      raise SavingsChallenge::AccessPolicy::Unavailable, "This tool is unavailable for this participant" unless actor&.participant? && !actor.revoked? && writable
      user = actor
      membership = if membership
        CohortMembership.where(user_id: user.id, role: "participant").find(membership.id)
      elsif cohort
        cohort.cohort_memberships.find_by(user_id: user.id, role: "participant")
      else
        Mia::EffectiveCohortResolver.new(user: user, role: "participant").call
      end
      if membership
        runtime = Mia::ParticipantRuntimeResolver.new(user: user, cohort_membership: membership).call
        snapshot = runtime.release&.tool_registry_snapshot
        version = runtime.release&.tool_registry_version
        if membership.cohort.savings_challenge_enabled
          SavingsChallenge::AccessPolicy.new(household: household, user: user, cohort: membership.cohort).call!
        end
        # Only a genuinely unreleased cohort may use the deployed default.
        # A resolver failure or a cohort that has ever sealed a release stays closed.
        if runtime.source == "prelaunch_default" && !membership.cohort.cohort_releases.exists? &&
            !ChallengePrivacy::PrivateFinanceAccess.pilot_household?(household)
          version = Contract::RUNTIME_TOOL_REGISTRY_VERSION
          snapshot = ToolContracts.fetch(version)
        end
        allowed = runtime.membership&.id == membership.id && runtime.cohort_id == membership.cohort_id &&
          ToolContracts.supported_snapshot?(snapshot, version: version) &&
          snapshot.fetch("operations").include?({ "key" => key, "version" => HouseholdFinance::Operations::Registry.fetch(key)::VERSION })
      else
        # Standalone participant tools use the current deployed contract. A
        # removed pilot membership cannot become this standalone exception.
        allowed = !ChallengePrivacy::PrivateFinanceAccess.pilot_household?(household) &&
          ToolContracts.fetch(Contract::RUNTIME_TOOL_REGISTRY_VERSION).fetch("operations").include?({ "key" => key, "version" => HouseholdFinance::Operations::Registry.fetch(key)::VERSION })
      end
      raise SavingsChallenge::AccessPolicy::Unavailable, "This part of your program isn't available right now. Please contact your program team." unless allowed
      true
    end
  end
end
