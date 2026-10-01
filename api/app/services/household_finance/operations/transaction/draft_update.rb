require_relative "base"

module HouseholdFinance
  module Operations
    module Transaction
      class DraftUpdate < Base
        KEY = "transaction.draft.update"
        VERSION = 1

        private

        def normalize(input)
          draft = household.transaction_drafts.find(input[:draft_id].to_i)
          source_type = normalized_source_type(input[:source_type])
          normalized = { draft_id: draft.id, source_type: source_type, year: draft.occurred_on.year }
          if input.key?(:occurred_on) && input[:occurred_on].present?
            occurred_on = parsed_date(input[:occurred_on])
            normalized[:occurred_on] = occurred_on.iso8601
            normalized[:year] = occurred_on.year
          end
          if input.key?(:merchant)
            merchant = bounded_text(input[:merchant], 120)
            raise ArgumentError, "Transaction merchant is required" if merchant.blank?
            normalized[:merchant] = merchant
          end
          if input.key?(:amount) || input.key?(:amount_cents)
            normalized[:amount_cents] = input.key?(:amount_cents) ? Integer(input.fetch(:amount_cents)) : parsed_amount_cents(input[:amount])
            raise ArgumentError, "Transaction amount must be greater than $0" unless normalized[:amount_cents].positive?
          end
          if input.key?(:budget_category_id) && input[:budget_category_id].present?
            normalized[:budget_category_id] = active_category(input[:budget_category_id]).id
          end
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
          elsif normalized[:amount_cents] && draft.transaction_draft_splits.one?
            split = draft.transaction_draft_splits.sole
            normalized[:splits] = normalized_update_splits(
              draft,
              [ {
                id: split.id,
                budget_category_id: normalized[:budget_category_id] || split.budget_category_id,
                category_name: normalized[:budget_category_id] ? nil : split.category_name,
                stack_key: normalized[:budget_category_id] ? nil : split.stack_key,
                amount_cents: normalized.fetch(:amount_cents),
                notes: split.notes
              } ],
              total_cents: normalized.fetch(:amount_cents)
            )
          elsif normalized[:amount_cents] && draft.transaction_draft_splits.many?
            raise ArgumentError, "This review has multiple category splits, so provide the new amount for each split"
          elsif normalized[:budget_category_id]
            splits = draft.transaction_draft_splits.order(:id).to_a
            if splits.many?
              raise ArgumentError, "This review has multiple category splits. Edit each split category so the receipt or statement amounts stay intact."
            end
            if splits.one?
              split = splits.first
              normalized[:splits] = normalized_update_splits(
                draft,
                [ { id: split.id, budget_category_id: normalized.fetch(:budget_category_id), amount_cents: split.amount_cents, notes: split.notes } ],
                total_cents: draft.total_amount_cents
              )
            end
          end
          raise ArgumentError, "Tell me what to change on that pending transaction review" if normalized.keys == %i[draft_id source_type year]

          normalized
        rescue TypeError, ArgumentError => e
          raise e unless e.message.match?(/invalid value for Integer|can't convert|base specified/)

          raise ArgumentError, "Transaction amount must be a number"
        end

        def subject_for(input, lock:)
          scope = household.transaction_drafts
          scope = scope.lock if lock
          scope.find(input.fetch(:draft_id))
        end

        def canonical_snapshot(draft, _input, lock:)
          draft_snapshot(draft, lock: lock)
        end

        def predicted_after(before, input)
          after = before.deep_symbolize_keys
          draft = after.fetch(:draft)
          draft[:occurred_on] = input[:occurred_on] if input.key?(:occurred_on)
          draft[:merchant] = input[:merchant] if input.key?(:merchant)
          draft[:total_amount_cents] = input[:amount_cents] if input.key?(:amount_cents)
          if input.key?(:splits)
            after[:splits] = canonical_split_order(input.fetch(:splits))
            draft[:budget_category_id] = stable_primary_category_id(draft[:budget_category_id], input.fetch(:splits))
          elsif input.key?(:budget_category_id)
            category = active_category(input.fetch(:budget_category_id))
            after[:splits] = [
              split_attributes(category, draft.fetch(:total_amount_cents)).merge(
                confidence: nil,
                metadata: { "human_reviewed_replacement" => true }
              )
            ]
            draft[:budget_category_id] = category.id
          end
          after
        end

        def validate_execution!(draft, input, prepared:, source:)
          validate_source!(input, source)
          raise ArgumentError, "Transaction draft is not pending" unless draft.pending?
        end

        def mutate!(draft, input, prepared:)
          attributes = {}
          attributes[:occurred_on] = input[:occurred_on] if input.key?(:occurred_on)
          attributes[:merchant] = input[:merchant] if input.key?(:merchant)
          attributes[:amount] = Money.dollars(input[:amount_cents]) if input.key?(:amount_cents)
          attributes[:budget_category_id] = input[:budget_category_id] if input.key?(:budget_category_id)
          attributes[:splits] = input.fetch(:splits).map { |split| split.merge(amount: Money.dollars(split.fetch(:amount_cents))).except(:amount_cents) } if input.key?(:splits)
          result = TransactionDraftUpdater.new(draft, attributes).call
          raise ArgumentError, result.errors.to_sentence unless result.success?

          result.draft
        end

        def canonical_after_snapshot(draft, _input, prepared:)
          draft_snapshot(draft.reload)
        end
      end
    end
  end
end
