module HouseholdFinance
  module Operations
    module Savings
      module Debt
        class Base < Savings::Base
          private

          def predicted_after(_before, _input) = { "private_change_completed" => true }
          def canonical_after_snapshot(_subject, _input, prepared:) = { "private_change_completed" => true }
          def stale_message = "Card terms changed. Review the current draft, approved version and source mapping. Nothing changed."
          def mapping = SavingsChallenge::Debt::SourceMapping.new(household)
          def card_for(id) = SavingsDebtCard.where(savings_enrollment: @enrollment).lock.find(id)

          def check_head!(card, input)
            check_version!(card.current_version_id, input[:expected_version_id])
            check_version!(card.lock_version, input[:expected_head_lock_version])
          end

          def validate_date!(terms, previous: nil)
            date = Date.iso8601(terms.fetch("as_of_on"))
            raise ArgumentError, "Current card terms cannot be approved as of a future date" if date > @enrollment.local_today
            raise ArgumentError, "An older statement cannot replace newer approved card terms" if previous && date < Date.iso8601(previous.terms.fetch("as_of_on"))
          end
        end
      end
    end
  end
end
