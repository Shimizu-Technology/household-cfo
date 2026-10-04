module HouseholdFinance
  module Operations
    module Savings
      module Daily
        class CheckInSave < Base
          KEY = "savings.daily.check_in.save"
          VERSION = 1

          private

          def normalize(input)
            input = normal_ids(input, required: %i[local_on spending_state accepted expected_version_id expected_head_lock_version], optional: %i[reason])
            raise ArgumentError, "Choose spending, no_spend or unknown explicitly" unless input[:spending_state].in?(%w[spending no_spend unknown])
            input.merge(local_on: SavingsChallenge::Inputs.date!(input[:local_on]).iso8601, accepted: SavingsChallenge::Inputs.accepted!(input[:accepted]),
              expected_version_id: SavingsChallenge::Inputs.id!(input[:expected_version_id], nullable: true),
              expected_head_lock_version: SavingsChallenge::Inputs.integer!(input[:expected_head_lock_version], minimum: 0),
              reason: SavingsChallenge::Inputs.text!(input[:reason], required: input[:expected_version_id].present?))
          end

          def subject_for(input, lock:)
            @enrollment = enrollment_for(input, lock: lock)
          end

          def mutate!(_subject, input, prepared:)
            date = SavingsChallenge::Daily::Inputs.elapsed_date!(@enrollment, input[:local_on])
            check_in = SavingsDailyCheckIn.find_or_create_by!(savings_enrollment: @enrollment, local_on: date)
            check_in.lock!
            check_head!(check_in, input)
            purchases = SavingsDailyPurchaseVersion.joins(:savings_daily_purchase).where(savings_enrollment: @enrollment, purchased_on: date, disposition: "purchase")
              .where("savings_daily_purchase_versions.id = savings_daily_purchases.current_version_id")
            if input[:spending_state] == "no_spend" && purchases.exists?
              raise ArgumentError, "Known approved purchases contradict no-spend; review the financial correction explicitly"
            end
            version = SavingsDailyCheckInVersion.create!(version_attributes(check_in, reason: input[:reason]).merge(
              savings_daily_check_in: check_in, spending_state: input[:spending_state], daily_sequence: ledger(@enrollment, lock: true).advance!))
            check_in.update!(current_version: version)
            version
          end
        end
      end
    end
  end
end
