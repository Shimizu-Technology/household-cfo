module HouseholdFinance
  module Operations
    module Savings
      class Base < Operations::Base
        ACTOR_REQUIRED = true
        SENSITIVE_AUDIT = true

        def initialize(household, user:)
          super(household)
          @user = user
        end

        def execute!(prepared, source:)
          normalized = normalized_input(prepared.normalized_input)
          raise ArgumentError, "Savings review input is invalid" unless normalized.deep_stringify_keys == prepared.normalized_input
          super
        end

        def authorize_replay!(subject)
          enrollment = subject.is_a?(SavingsEnrollment) ? subject : subject.savings_enrollment
          authorize!(enrollment.cohort_id, enrollment: enrollment, lock: true)
          enrollment.lock!
          raise SavingsChallenge::AccessPolicy::Unavailable, "This savings enrollment is unavailable" unless enrollment.status.in?(%w[active completed])
        end

        private

        attr_reader :user

        def ensure_plan!(_input); end

        def authorize!(cohort_id, enrollment: nil, lock: false)
          cohort = Cohort.find(cohort_id)
          SavingsChallenge::AccessPolicy.new(household: household, user: user, cohort: cohort, enrollment: enrollment, lock: lock).call!
          CohortReleases::OperationAccess.require!(household: household, user: user, key: self.class::KEY, cohort: cohort)
          cohort
        end

        def enrollment_for(input, lock:)
          enrollment = SavingsEnrollment.find_by!(household_id: household.id, user_id: user.id, cohort_id: input.fetch(:cohort_id))
          authorize!(input.fetch(:cohort_id), enrollment: enrollment, lock: lock)
          enrollment.lock! if lock
          raise ArgumentError, "This enrollment does not accept financial changes" unless enrollment.status == "active"
          enrollment
        end

        def canonical_snapshot(subject, _input, lock:)
          subject.attributes
        end

        def predicted_after(before, input)
          JSON.parse(JSON.generate(planned_record(before, input)))
        end

        def canonical_after_snapshot(subject, _input, prepared:)
          JSON.parse(JSON.generate(subject.reload.attributes.slice(*prepared.predicted_after_snapshot.keys)))
        end

        def verify_after!(predicted, actual)
          raise ArgumentError, "Savings result did not match the participant's reviewed change" unless predicted == actual
        end

        def stale_message
          "Savings review changed. Review the current draft and versions before approving. Nothing changed."
        end

        def check_version!(actual, expected)
          raise StaleOperation, stale_message unless actual == expected
        end

        def normal_ids(input, required:, optional: [])
          SavingsChallenge::Inputs.keys!(input, required: [ :cohort_id, *required ], optional: optional)
          input.merge(cohort_id: SavingsChallenge::Inputs.id!(input.fetch(:cohort_id)))
        end
      end
    end
  end
end
