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
        current = SavingsEnrollment.find(enrollment.id)
        cohort = Cohort.find(current.cohort_id)
        actor = User.find(user.id)
        membership = current.household.household_memberships.find_by(user_id: actor.id)
        allowed = SavingsChallenge::ProgramMode.state(cohort) == "paused" && actor.participant? && !actor.revoked? &&
          current.user_id == actor.id && current.household_id == membership&.household_id && membership.role.in?(%w[owner partner]) &&
          current.status.in?(%w[active completed]) &&
          cohort.cohort_memberships.exists?(id: current.accepted_cohort_membership_id, user_id: actor.id, role: "participant")
        raise unless allowed
        true
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
