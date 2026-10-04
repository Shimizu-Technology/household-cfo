module HouseholdFinance
  module Operations
    module Savings
      class EnrollmentAccept < Base
        KEY = "savings.enrollment.accept"
        VERSION = 1

        private

        def normalize(input)
          input = normal_ids(input, required: %i[participation_accepted policy_version late_start_accepted expected_acceptance_digest])
          SavingsChallenge::Inputs.accepted!(input[:participation_accepted])
          raise ArgumentError, "Late-start acceptance must be true or false" unless [ true, false ].include?(input[:late_start_accepted])
          raise ArgumentError, "Participation policy version is required" unless input[:policy_version].instance_of?(String) && input[:policy_version].length.between?(1, 100)
          raise ArgumentError, "Review the current challenge offer" unless input[:expected_acceptance_digest].instance_of?(String) && input[:expected_acceptance_digest].match?(/\A[0-9a-f]{64}\z/)
          input
        end

        def subject_for(input, lock:)
          authorize!(input.fetch(:cohort_id), lock: lock)
        end

        def canonical_snapshot(cohort, _input, lock:)
          @acceptance_time ||= Time.current
          membership = cohort.cohort_memberships.find_by!(user_id: user.id, role: "participant")
          offer = SavingsChallenge::EnrollmentOffer.call(cohort: cohort, user: user, membership: membership, at: @acceptance_time)
          {
            cohort: cohort.attributes.slice("id", "starts_on", "status", "savings_challenge_capacity", "savings_challenge_policy_version"),
            accepted_local_on: @acceptance_time.in_time_zone(SavingsEnrollment::TIME_ZONE).to_date.iso8601,
            offer_digest: offer.fetch(:acceptance_digest),
            enrolled: SavingsEnrollment.exists?(cohort_id: cohort.id, user_id: user.id)
          }
        end

        def mutate!(cohort, input, prepared:)
          raise ArgumentError, "This cohort is not accepting savings enrollment" unless cohort.status.in?(%w[enrolling active]) && cohort.starts_on
          raise ArgumentError, "Participation terms changed; review the current version" unless input[:policy_version] == cohort.savings_challenge_policy_version
          raise StaleOperation, "The challenge offer changed. Review its dates and terms before joining." unless input[:expected_acceptance_digest] == prepared.before_snapshot.fetch("offer_digest")
          raise StaleOperation, "This participant is already enrolled" if SavingsEnrollment.exists?(cohort_id: cohort.id, user_id: user.id)
          raise ArgumentError, "This savings cohort has reached its participant capacity" if SavingsEnrollment.where(cohort_id: cohort.id).count >= cohort.savings_challenge_capacity
          local = @acceptance_time.in_time_zone(SavingsEnrollment::TIME_ZONE).to_date
          late = local > cohort.starts_on
          raise ArgumentError, "Accept the personal late-start window before joining" if late && !input[:late_start_accepted]
          membership = cohort.cohort_memberships.find_by!(user_id: user.id, role: "participant")
          runtime = SavingsChallenge::AccessPolicy.runtime_for(user: user, membership: membership)
          raise SavingsChallenge::AccessPolicy::Unavailable, "Review the current challenge release before joining" unless runtime
          start = [ cohort.starts_on, local ].max
          SavingsEnrollment.create!(
            household: household, user: user, cohort: cohort, accepted_cohort_membership_id: membership.id,
            accepted_cohort_release: runtime.release,
            membership_started_at: membership.created_at, accepted_at: @acceptance_time, accepted_local_on: local,
            starts_on: start, ends_on: start + 89, time_zone: SavingsEnrollment::TIME_ZONE,
            policy_version: input[:policy_version], late_start_accepted: late
          )
        end

        def planned_record(before, input)
          local = Date.iso8601(before.fetch("accepted_local_on"))
          start = [ Date.parse(before.fetch("cohort").fetch("starts_on").to_s), local ].max
          { household_id: household.id, user_id: user.id, cohort_id: input[:cohort_id],
            starts_on: start, ends_on: start + 89, time_zone: SavingsEnrollment::TIME_ZONE,
            policy_version: input[:policy_version], status: "active" }
        end
      end
    end
  end
end
