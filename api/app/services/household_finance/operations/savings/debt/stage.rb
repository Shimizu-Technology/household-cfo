module HouseholdFinance
  module Operations
    module Savings
      module Debt
        class Stage < Base
          KEY = "savings.debt.stage"
          VERSION = 1

          private

          def normalize(input)
            input = normal_ids(input, required: %i[terms expected_version_id expected_head_lock_version], optional: %i[card_id source_mapping reason])
            input.merge(card_id: SavingsChallenge::Inputs.id!(input[:card_id], nullable: true),
              expected_version_id: SavingsChallenge::Inputs.id!(input[:expected_version_id], nullable: true),
              expected_head_lock_version: SavingsChallenge::Inputs.integer!(input[:expected_head_lock_version], minimum: 0),
              terms: SavingsChallenge::Debt::Terms.normalize(input[:terms]), source_mapping: mapping.normalize(input[:source_mapping]),
              reason: SavingsChallenge::Inputs.text!(input[:reason], required: input[:expected_version_id].present?))
          end

          def subject_for(input, lock:)
            @enrollment = enrollment_for(input, lock: lock)
          end

          def mutate!(_subject, input, prepared:)
            terms = input[:terms].deep_stringify_keys
            source = mapping.resolve!(input[:source_mapping], as_of_on: terms.fetch("as_of_on"))
            card = if input[:card_id]
              card_for(input[:card_id])
            else
              check_version!(input[:expected_version_id], nil); check_version!(input[:expected_head_lock_version], 0)
              raise ArgumentError, "Maximum 100 card identities reached. Review an existing card" if SavingsDebtCard.where(savings_enrollment: @enrollment).count >= 100
              SavingsDebtCard.create!(savings_enrollment: @enrollment, household: household, user: user)
            end
            check_head!(card, input)
            validate_date!(terms, previous: card.current_version)
            card.savings_debt_drafts.create!(savings_enrollment: @enrollment, created_by_user: user,
              base_version_id: card.current_version_id, base_head_lock_version: card.lock_version, terms: terms, reason: input[:reason], **source)
          end
        end
      end
    end
  end
end
