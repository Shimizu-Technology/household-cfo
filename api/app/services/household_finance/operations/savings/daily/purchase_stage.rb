module HouseholdFinance
  module Operations
    module Savings
      module Daily
        class PurchaseStage < Base
          KEY = "savings.daily.purchase.stage"
          VERSION = 1

          private

          def normalize(input)
            input = normal_ids(input, required: %i[amount_cents merchant purchased_on splits link_kind expected_version_id],
              optional: %i[disposition purchase_id expected_head_lock_version linked_transaction_id expected_canonical_digest reason])
            disposition = input.fetch(:disposition, "purchase")
            raise ArgumentError, "Choose purchase or an explicit manual void correction" unless disposition.in?(%w[purchase void])
            amount = SavingsChallenge::Inputs.integer!(input[:amount_cents], minimum: disposition == "void" ? 0 : 1, maximum: SavingsChallenge::Daily::Inputs::MAX_AMOUNT_CENTS)
            if disposition == "void" && (amount != 0 || input[:splits] != [] || !input[:purchase_id] || !input[:expected_version_id] || input[:link_kind] != "manual_new")
              raise ArgumentError, "Void requires an existing approved manual purchase, zero cents and no splits"
            end
            raise ArgumentError, "Choose an explicit canonical purchase link" unless input[:link_kind].in?(%w[manual_new existing_transaction])
            linked = SavingsChallenge::Inputs.id!(input[:linked_transaction_id], nullable: true)
            digest = input[:expected_canonical_digest]
            if input[:link_kind] == "existing_transaction"
              raise ArgumentError, "Review the existing canonical purchase before linking" unless linked && digest.instance_of?(String) && digest.match?(/\A[0-9a-f]{64}\z/)
            elsif linked || digest
              raise ArgumentError, "A new manual purchase cannot impersonate an existing source link"
            end
            input.merge(disposition: disposition, amount_cents: amount, merchant: SavingsChallenge::Daily::Inputs.text!(input[:merchant], limit: 120, required: true),
              purchased_on: SavingsChallenge::Inputs.date!(input[:purchased_on]).iso8601, splits: disposition == "void" ? [] : SavingsChallenge::Daily::Inputs.splits!(input[:splits], amount),
              purchase_id: SavingsChallenge::Inputs.id!(input[:purchase_id], nullable: true), linked_transaction_id: linked,
              expected_canonical_digest: digest, expected_version_id: SavingsChallenge::Inputs.id!(input[:expected_version_id], nullable: true),
              expected_head_lock_version: SavingsChallenge::Inputs.integer!(input.fetch(:expected_head_lock_version, 0), minimum: 0),
              reason: SavingsChallenge::Inputs.text!(input[:reason], required: input[:expected_version_id].present?))
          end

          def subject_for(input, lock:)
            @enrollment = enrollment_for(input, lock: lock)
          end

          def mutate!(_subject, input, prepared:)
            date = SavingsChallenge::Daily::Inputs.elapsed_date!(@enrollment, input[:purchased_on], future_draft: true)
            purchase = if input[:purchase_id]
              SavingsDailyPurchase.where(savings_enrollment: @enrollment).lock.find(input[:purchase_id])
            else
              check_version!(input[:expected_version_id], nil)
              check_version!(input[:expected_head_lock_version], 0)
              SavingsDailyPurchase.create!(savings_enrollment: @enrollment)
            end
            check_head!(purchase, input)
            previous = purchase.current_version
            raise ArgumentError, "A voided daily purchase cannot be reused; stage a new purchase" if previous&.disposition == "void"
            if previous && input[:link_kind] == "manual_new" && previous.link_kind != "manual_new"
              raise ArgumentError, "Source-owned purchases require their canonical source workflow"
            end
            canonical = SavingsChallenge::Daily::CanonicalPurchase.new(@enrollment)
            canonical.validate_previous!(previous) if previous&.link_kind == "manual_new"
            if input[:disposition] == "void" && (input[:merchant] != previous.merchant || date != previous.purchased_on)
              raise ArgumentError, "Void retains the original purchase identity and date"
            end
            canonical.categories!(input[:splits].map(&:deep_stringify_keys))
            digest = input[:expected_canonical_digest]
            digest ||= SavingsChallenge::Daily::CanonicalPurchase.digest(previous.household_transaction) if previous
            draft = SavingsDailyPurchaseDraft.create!(savings_enrollment: @enrollment, savings_daily_purchase: purchase,
              created_by_user: user, base_version_id: purchase.current_version_id, base_head_lock_version: purchase.lock_version,
              disposition: input[:disposition], amount_cents: input[:amount_cents], merchant: input[:merchant], purchased_on: date, splits: input[:splits],
              link_kind: input[:link_kind], linked_transaction_id: input[:linked_transaction_id], canonical_digest: digest,
              previous_canonical_digest: previous && SavingsChallenge::Daily::CanonicalPurchase.digest(previous.household_transaction), reason: input[:reason])
            canonical.link!(input[:linked_transaction_id], expected_digest: digest, draft: draft, purchase: purchase) if input[:linked_transaction_id]
            draft
          end
        end
      end
    end
  end
end
