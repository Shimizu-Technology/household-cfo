module HouseholdFinance
  module Operations
    module Savings
      module Daily
        class ReflectionErase < Base
          KEY = "savings.daily.reflection.erase"
          VERSION = 1

          def authorize_replay!(subject)
            enrollment = subject.savings_enrollment
            raise SavingsChallenge::AccessPolicy::Unavailable, "This private reflection is unavailable" unless enrollment.household_id == household.id
            SavingsChallenge::Daily::ReadPolicy.erase!(enrollment, user: user, lock: true)
            enrollment.lock!
          end

          private

          def normalize(input)
            input = normal_ids(input, required: %i[reflection_id erase_accepted expected_version_id expected_head_lock_version])
            input.merge(reflection_id: SavingsChallenge::Inputs.id!(input[:reflection_id]),
              erase_accepted: SavingsChallenge::Inputs.accepted!(input[:erase_accepted]), expected_version_id: SavingsChallenge::Inputs.id!(input[:expected_version_id]),
              expected_head_lock_version: SavingsChallenge::Inputs.integer!(input[:expected_head_lock_version], minimum: 0))
          end

          def subject_for(input, lock:)
            enrollment = SavingsEnrollment.find_by!(household_id: household.id, user_id: user.id, cohort_id: input[:cohort_id])
            SavingsChallenge::Daily::ReadPolicy.erase!(enrollment, user: user, lock: lock)
            enrollment.lock! if lock
            reflection = SavingsDailyReflection.where(savings_enrollment: enrollment).find(input[:reflection_id])
            reflection.lock! if lock
            reflection
          end

          def mutate!(reflection, input, prepared:)
            check_head!(reflection, input)
            SavingsDailyReflectionVersion.where(savings_daily_reflection: reflection, erased_at: nil).update_all(
              feeling_then: nil, feeling_now: nil, reason: "", erased_at: Time.current, erased_by_user_id: user.id, updated_at: Time.current)
            reflection.touch
            reflection.current_version.reload
          end
        end
      end
    end
  end
end
