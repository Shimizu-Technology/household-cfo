module HouseholdFinance
  module Operations
    module Privacy
      class Base < Operations::Base
        ACTOR_REQUIRED = true
        SENSITIVE_AUDIT = true
        VERSION = 1
        def initialize(household, user:)
          super(household)
          @domain = ChallengePrivacy::Domain.new(household, user: user)
        end
        def prepare(input)
          ApplicationRecord.transaction do
            household.lock!
            super
          end
        end
        def execute!(prepared, source:)
          ApplicationRecord.transaction do
            household.lock!
            input = normalized_input(prepared.normalized_input)
            raise ArgumentError, "Privacy review input changed" unless input.deep_stringify_keys == prepared.normalized_input
            super
          end
        end
        def authorize_replay!(subject)
          raise ChallengePrivacy::Access::Denied, "This privacy approval is unavailable" unless subject.is_a?(ChallengePrivacyEvent) && subject.household_id == household.id
          ApplicationRecord.transaction do
            household.lock!
            domain.authorize!(domain.enrollment(subject.savings_enrollment_id))
            raise ChallengePrivacy::Access::Denied, "This privacy approval is unavailable" unless subject.actor_user_id == domain.user.id
          end
        end
        def verify_after!(predicted, actual)
          raise ArgumentError, "Privacy result differs from the reviewed request" unless predicted.deep_stringify_keys == actual.deep_stringify_keys
          true
        end

        private
        attr_reader :domain
        def normalize(input) = domain.normalize(self.class::ACTION, input)
        def ensure_plan!(_input) = nil
        def subject_for(input, lock:) = domain.enrollment(input[:enrollment_id])
        def canonical_snapshot(subject, input, lock:)
          privacy_exit = self.class::ACTION.in?(%w[support_revoke source_revoke]) || (self.class::ACTION == "consent" && input[:granted] == false)
          CohortReleases::OperationAccess.require!(household: household, user: domain.user, key: self.class::KEY, cohort: subject.cohort) unless privacy_exit
          domain.snapshot(self.class::ACTION, input)
        end
        def validate_execution!(subject, _input, prepared:, source:) = domain.authorize!(subject)
        def mutate!(_subject, input, prepared:) = domain.execute(self.class::ACTION, input)
        def predicted_after(_before, input) = { action: self.class::ACTION, approved_values_digest: domain.digest(input.except(:enrollment_id)) }
        def canonical_after_snapshot(subject, _input, prepared:) = { action: subject.action, approved_values_digest: domain.digest(subject.approved_values) }
        def stale_message = "This privacy choice changed. Review the current scope; nothing changed."
      end
    end
  end
end
