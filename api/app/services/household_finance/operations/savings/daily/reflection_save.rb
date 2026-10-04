module HouseholdFinance
  module Operations
    module Savings
      module Daily
        class ReflectionSave < Base
          KEY = "savings.daily.reflection.save"
          VERSION = 1

          private

          def normalize(input)
            input = normal_ids(input, required: %i[purchase_id expected_version_id expected_head_lock_version], optional: %i[feeling_then feeling_now])
            input.merge(purchase_id: SavingsChallenge::Inputs.id!(input[:purchase_id]),
              expected_version_id: SavingsChallenge::Inputs.id!(input[:expected_version_id], nullable: true),
              expected_head_lock_version: SavingsChallenge::Inputs.integer!(input[:expected_head_lock_version], minimum: 0),
              feeling_then: SavingsChallenge::Daily::Inputs.text!(input[:feeling_then], limit: 500),
              feeling_now: SavingsChallenge::Daily::Inputs.text!(input[:feeling_now], limit: 500))
          end

          def subject_for(input, lock:)
            @enrollment = enrollment_for(input, lock: lock)
            @purchase = SavingsDailyPurchase.where(savings_enrollment: @enrollment).find(input[:purchase_id])
            # Feelings can accompany a draft. No purchase approval is implied.
            @enrollment
          end

          def mutate!(_subject, input, prepared:)
            reflection = SavingsDailyReflection.find_or_create_by!(savings_enrollment: @enrollment, savings_daily_purchase: @purchase)
            reflection.lock!
            check_head!(reflection, input)
            version = SavingsDailyReflectionVersion.create!(version_attributes(reflection, reason: "Participant saved optional reflection").merge(
              savings_daily_reflection: reflection, feeling_then: input[:feeling_then], feeling_now: input[:feeling_now]))
            reflection.update!(current_version: version)
            version
          end
        end
      end
    end
  end
end
