module SavingsChallenge
  module Daily
    class ReadPolicy
      def self.call!(enrollment, user:)
        current = SavingsEnrollment.find(enrollment.id)
        SavingsChallenge::AccessPolicy.new(household: current.household, user: user, cohort: Cohort.find(current.cohort_id), enrollment: current).call!
        CohortReleases::OperationAccess.require!(household: current.household, user: user,
          key: "savings.daily.check_in.save", cohort: current.cohort)
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
