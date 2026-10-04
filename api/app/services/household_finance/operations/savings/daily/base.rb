module HouseholdFinance
  module Operations
    module Savings
      module Daily
        class Base < Savings::Base
          private

          def enrollment_for(input, lock:)
            enrollment = SavingsEnrollment.find_by!(household_id: household.id, user_id: user.id, cohort_id: input.fetch(:cohort_id))
            authorize!(input[:cohort_id], enrollment: enrollment, lock: lock)
            enrollment.lock! if lock
            enrollment
          end

          def ledger(enrollment, lock:)
            record = SavingsDailyLedger.find_by(savings_enrollment: enrollment)
            record ||= SavingsDailyLedger.create!(savings_enrollment: enrollment) if lock
            record&.lock! if lock
            record
          end

          def version_attributes(head, reason:)
            previous = head.current_version
            { savings_enrollment: head.savings_enrollment, approved_by_user: user, previous_version: previous,
              version_number: previous ? previous.version_number + 1 : 1, approved_at: Time.current, reason: reason }
          end

          def check_head!(head, input)
            check_version!(head.current_version_id, input[:expected_version_id])
            check_version!(head.lock_version, input[:expected_head_lock_version])
          end

          def predicted_after(_before, _input)
            # Private records are verified in their domain service and DB guards.
            # The generic runner receives only a safe completion envelope.
            { "private_change_completed" => true }
          end

          def canonical_after_snapshot(_subject, _input, prepared:)
            { "private_change_completed" => true }
          end

          def stale_message
            "The private daily record changed. Review the current versions before saving. Nothing changed."
          end
        end
      end
    end
  end
end
