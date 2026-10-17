module SavingsChallenge
  module Daily
    class ReadPolicy
      def self.call!(enrollment, user:)
        current = SavingsEnrollment.find(enrollment.id)
        SavingsChallenge::AccessPolicy.new(household: current.household, user: user, cohort: Cohort.find(current.cohort_id), enrollment: current).call!
        CohortReleases::OperationAccess.require!(household: current.household, user: user,
          key: "savings.daily.check_in.save", cohort: current.cohort)
      end

      # A participant may always download their OWN record, including while the
      # challenge is paused (release hold). Self-only: same owner/partner and
      # enrollment checks, no new financial activity and no other reads.
      def self.export!(enrollment, user:)
        call!(enrollment, user: user)
      rescue SavingsChallenge::AccessPolicy::Unavailable
        raise unless paused_self_export_allowed?(enrollment, user)

        true
      end

      # Same identity checks as AccessPolicy, minus the enabled/hold flags and the
      # daily-operation gate, and only while the cohort is paused (enabled + hold).
      def self.paused_self_export_allowed?(enrollment, user)
        current = SavingsEnrollment.find(enrollment.id)
        cohort = Cohort.find(current.cohort_id)
        actor = User.find(user.id)
        return false unless SavingsChallenge::ProgramMode.state(cohort) == "paused" && cohort.status.in?(%w[enrolling active completed])

        role = current.household.household_memberships.find_by(user_id: actor.id)&.role
        membership = cohort.cohort_memberships.find_by(user_id: actor.id, role: "participant")
        actor.participant? && !actor.revoked? && role.in?(%w[owner partner]) && membership.present? &&
          current.user_id == actor.id && current.status.in?(%w[active completed]) &&
          current.accepted_cohort_membership_id == membership.id && current.membership_started_at == membership.created_at &&
          current.accepted_cohort_release&.cohort_id == cohort.id &&
          SavingsChallenge::AccessPolicy.runtime_allowed?(user: actor, membership: membership)
      end

      # Erasure is a self-only privacy operation. It grants neither program
      # reads nor new content while a program is held, withdrawn or unavailable.
      def self.erase!(enrollment, user:, lock: false)
        actor = lock ? User.lock.find(user.id) : User.find(user.id)
        membership = enrollment.household.household_memberships.find_by(user_id: actor.id)
        allowed = enrollment.user_id == actor.id && !actor.revoked? && membership&.role.in?(%w[owner partner])
        raise SavingsChallenge::AccessPolicy::Unavailable, "This private reflection is unavailable for this actor" unless allowed
        true
      end
    end
  end
end
