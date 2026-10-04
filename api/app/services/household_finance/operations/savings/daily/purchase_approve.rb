module HouseholdFinance
  module Operations
    module Savings
      module Daily
        class PurchaseApprove < Base
          KEY = "savings.daily.purchase.approve"
          VERSION = 1

          private

          def normalize(input)
            input = normal_ids(input, required: %i[draft_id accepted expected_draft_lock_version expected_version_id expected_head_lock_version])
            input.merge(draft_id: SavingsChallenge::Inputs.id!(input[:draft_id]), accepted: SavingsChallenge::Inputs.accepted!(input[:accepted]),
              expected_draft_lock_version: SavingsChallenge::Inputs.integer!(input[:expected_draft_lock_version], minimum: 0),
              expected_version_id: SavingsChallenge::Inputs.id!(input[:expected_version_id], nullable: true),
              expected_head_lock_version: SavingsChallenge::Inputs.integer!(input[:expected_head_lock_version], minimum: 0))
          end

          def subject_for(input, lock:)
            @enrollment = enrollment_for(input, lock: lock)
            draft = SavingsDailyPurchaseDraft.where(savings_enrollment: @enrollment).find(input[:draft_id])
            @purchase = draft.savings_daily_purchase
            @purchase.lock! if lock
            draft.lock! if lock
            draft
          end

          def mutate!(draft, input, prepared:)
            raise StaleOperation, stale_message unless draft.status == "pending"
            check_head!(@purchase, input)
            check_version!(draft.lock_version, input[:expected_draft_lock_version])
            check_version!(draft.base_version_id, input[:expected_version_id])
            check_version!(draft.base_head_lock_version, input[:expected_head_lock_version])
            SavingsChallenge::Daily::Inputs.elapsed_date!(@enrollment, draft.purchased_on)
            check_in = SavingsDailyCheckIn.find_by(savings_enrollment: @enrollment, local_on: draft.purchased_on)
            if draft.disposition == "purchase" && check_in&.current_version&.spending_state == "no_spend"
              raise ArgumentError, "Explicitly correct the reported no-spend check-in before approving this purchase"
            end
            canonical = SavingsChallenge::Daily::CanonicalPurchase.new(@enrollment)
            previous = @purchase.current_version
            transaction = if draft.disposition == "void"
              canonical.retire_owned!(previous, expected_digest: draft.previous_canonical_digest)
              previous.household_transaction.reload
            elsif draft.link_kind == "existing_transaction"
              linked = canonical.link!(draft.linked_transaction_id, expected_digest: draft.canonical_digest, draft: draft, purchase: @purchase)
              canonical.retire_owned!(previous, expected_digest: draft.previous_canonical_digest, replacement: linked) if previous&.link_kind == "manual_new"
              linked
            else
              canonical.publish!(draft, previous: previous)
            end
            version = SavingsDailyPurchaseVersion.create!(version_attributes(@purchase, reason: draft.reason).merge(
              savings_daily_purchase: @purchase, daily_sequence: ledger(@enrollment, lock: true).advance!, household_transaction: transaction,
              disposition: draft.disposition, amount_cents: draft.amount_cents, merchant: draft.merchant, purchased_on: draft.purchased_on,
              splits: draft.splits, link_kind: draft.link_kind, posted_on: transaction.financial_source_event&.posted_on))
            @purchase.update!(current_version: version)
            draft.update!(status: "approved", approved_version: version)
            version
          end
        end
      end
    end
  end
end
