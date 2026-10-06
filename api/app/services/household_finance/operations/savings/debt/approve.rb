module HouseholdFinance
  module Operations
    module Savings
      module Debt
        class Approve < Base
          KEY = "savings.debt.approve"
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
            draft = SavingsDebtDraft.where(savings_enrollment: @enrollment).find(input[:draft_id])
            @card = draft.savings_debt_card
            @card.lock! if lock
            draft.lock! if lock
            draft
          end

          def mutate!(draft, input, prepared:)
            raise StaleOperation, stale_message unless draft.status == "pending"
            check_head!(@card, input)
            check_version!(draft.lock_version, input[:expected_draft_lock_version])
            check_version!(draft.base_version_id, input[:expected_version_id])
            check_version!(draft.base_head_lock_version, input[:expected_head_lock_version])
            validate_date!(draft.terms, previous: @card.current_version)
            if draft.source_account_identity_version_id
              source = mapping.resolve!({ source_tracked_account_id: draft.source_tracked_account_id,
                source_account_identity_version_id: draft.source_account_identity_version_id, source_revision_approval_id: draft.source_revision_approval_id,
                fingerprint: draft.source_fingerprint }, as_of_on: draft.terms.fetch("as_of_on"))
              raise StaleOperation, stale_message unless source == mapping.values(draft)
            end
            if draft.household_debt_id
              household_source = household_mapping.resolve!({ household_debt_id: draft.household_debt_id, fingerprint: draft.household_debt_fingerprint })
              raise StaleOperation, stale_message unless household_source == household_mapping.values(draft)
              duplicate_household = SavingsDebtCard.where(savings_enrollment: @enrollment, household_debt_id: draft.household_debt_id).where.not(id: @card.id)
              raise ArgumentError, "This saved household card already has an optional identity. Review its existing terms." if duplicate_household.exists?
            end
            duplicate = SavingsDebtCard.where(savings_enrollment: @enrollment, source_tracked_account_id: draft.source_tracked_account_id).where.not(id: @card.id)
            raise ArgumentError, "This liability account already has a card identity. Review its existing terms." if draft.source_tracked_account_id && duplicate.exists?
            previous = @card.current_version
            attributes = mapping.values(draft).merge(household_mapping.values(draft)).merge(savings_enrollment: @enrollment, approved_by_user: user, previous_version: previous,
              version_number: previous ? previous.version_number + 1 : 1, terms: draft.terms, reason: draft.reason, approved_at: Time.current)
            version = @card.savings_debt_versions.create!(**attributes, digest: PreparedOperation.fingerprint(terms: draft.terms, source: mapping.values(draft), household_source: household_mapping.values(draft), previous_version_id: previous&.id))
            @card.update!(current_version: version, source_tracked_account_id: version.source_tracked_account_id, household_debt_id: version.household_debt_id)
            draft.update!(status: "approved", approved_version: version)
            version
          end
        end
      end
    end
  end
end
