require_relative "base"

module HouseholdFinance
  module Operations
    module Transaction
      class DraftConfirm < Base
        KEY = "transaction.draft.confirm"
        VERSION = 1

        private

        def normalize(input)
          draft = household.transaction_drafts.find(input[:draft_id].to_i)
          require_legacy_draft!(draft)
          source_type = normalized_source_type(input[:source_type])
          normalized = { draft_id: draft.id, source_type: source_type, year: draft.occurred_on.year }
          if input[:occurred_on].present?
            occurred_on = parsed_date(input[:occurred_on])
            normalized[:occurred_on] = occurred_on.iso8601
            normalized[:year] = occurred_on.year
          end
          if input.key?(:merchant)
            merchant = bounded_text(input[:merchant], 120)
            raise ArgumentError, "Transaction merchant is required" if merchant.blank?

            normalized[:merchant] = merchant
          end
          if input[:amount].present?
            normalized[:amount_cents] = parsed_amount_cents(input[:amount])
          end
          normalized[:budget_category_id] = active_category(input[:budget_category_id]).id if input[:budget_category_id].present?
          if input.key?(:splits)
            total_cents = normalized[:amount_cents] || draft.total_amount_cents
            removed_split_ids = normalized_removed_split_ids(input[:removed_split_ids])
            normalized[:removed_split_ids] = removed_split_ids if input.key?(:removed_split_ids)
            normalized[:splits] = normalized_update_splits(
              draft,
              input[:splits],
              total_cents: total_cents,
              removed_split_ids: removed_split_ids,
              allow_split_changes: source_type == "manual_ui"
            )
          end
          normalized
        end

        def ensure_plan!(_input)
          true
        end

        def subject_for(input, lock:)
          scope = household.transaction_drafts
          scope = scope.lock if lock
          scope.find(input.fetch(:draft_id))
        end

        def canonical_snapshot(draft, _input, lock:)
          resolution_snapshot(draft, lock: lock)
        end

        def predicted_after(before, input)
          before.deep_symbolize_keys.tap do |snapshot|
            snapshot.fetch(:draft)[:status] = input.keys.intersect?(%i[occurred_on merchant amount_cents budget_category_id splits]) ? "corrected" : "confirmed"
          end
        end

        def validate_execution!(draft, input, prepared:, source:)
          require_legacy_draft!(draft)
          validate_source!(input, source)
          raise ArgumentError, "Transaction draft is not pending" unless draft.pending?
        end

        def mutate!(draft, input, prepared:)
          attributes = {}
          attributes[:occurred_on] = input[:occurred_on] if input.key?(:occurred_on)
          attributes[:merchant] = input[:merchant] if input.key?(:merchant)
          attributes[:amount] = Money.dollars(input[:amount_cents]) if input.key?(:amount_cents)
          attributes[:budget_category_id] = input[:budget_category_id] if input.key?(:budget_category_id)
          if input.key?(:splits)
            attributes[:splits] = input.fetch(:splits).map do |split|
              split.merge(amount: Money.dollars(split.fetch(:amount_cents))).except(:amount_cents, :confidence, :metadata)
            end
          end
          result = TransactionDraftConfirmer.new(draft, attributes).call
          raise ArgumentError, result.errors.to_sentence unless result.success?

          result.draft
        end

        def canonical_after_snapshot(draft, _input, prepared:)
          resolution_snapshot(draft.reload)
        end

        def verify_after!(_predicted, actual)
          snapshot = actual.deep_stringify_keys
          status = snapshot.dig("draft", "status")
          return true if status.in?(%w[confirmed corrected]) && snapshot["transaction"].present?

          raise ArgumentError, "The transaction confirmation did not match the requested change. Nothing changed."
        end
      end
    end
  end
end
