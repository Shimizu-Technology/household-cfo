module HouseholdFinance
  module Operations
    module Transaction
      class Base < Operations::Base
        MAX_SPLITS = DocumentTransactionDraftPersister::MAX_SPLITS

        private

        def parsed_date(value)
          date = Date.iso8601(value.to_s)
          raise ArgumentError, "Transaction date is outside supported budget years" unless AnnualBudgetManager.supported_year?(date.year)
          raise ArgumentError, "Transaction date cannot be in the future" if date > Date.current

          date
        rescue Date::Error
          raise ArgumentError, "Transaction date is invalid"
        end

        def parsed_amount_cents(value, message: "Transaction amount must be a number")
          cents = Money.cents!(value, message: message)
          raise ArgumentError, "Transaction amount must be greater than $0" unless cents.positive?

          cents
        end

        def bounded_text(value, max_length)
          value.to_s.unicode_normalize(:nfkc).gsub(/[[:cntrl:]]/, " ").gsub(/[<>`]/, "").squish.truncate(max_length, omission: "…")
        end

        def active_category(id)
          return if id.blank? || id.to_i.zero?

          category = household.budget_categories.find_by(id: id.to_i)
          raise ArgumentError, "Budget category not found" unless category
          raise ArgumentError, "Budget category is archived. Restore it or choose an active category before confirming." unless category.active?

          category
        end

        def normalized_source_type(value)
          source_type = value.to_s
          raise ArgumentError, "Transaction source is not supported" unless source_type.in?(%w[manual_ui manual_chat])

          source_type
        end

        def validate_source!(input, source)
          expected = source.to_s == "mia" ? "manual_chat" : "manual_ui"
          return if input.fetch(:source_type) == expected

          raise ArgumentError, "Transaction source does not match this request"
        end

        def normalized_splits(values, total_cents:, fallback_category: nil, allow_uncategorized: true)
          raw = Array(values)
          raise ArgumentError, "Add no more than #{MAX_SPLITS} transaction splits" if raw.length > MAX_SPLITS
          if raw.empty?
            return [ split_attributes(fallback_category, total_cents) ] if allow_uncategorized || fallback_category

            raise ArgumentError, "Transaction splits are required"
          end

          splits = raw.map.with_index do |value, index|
            split = value.to_h.deep_symbolize_keys
            category = active_category(split[:budget_category_id] || split[:category_id])
            amount_cents = split.key?(:amount_cents) ? Integer(split.fetch(:amount_cents)) : parsed_amount_cents(split[:amount], message: "Split #{index + 1} amount must be a number")
            raise ArgumentError, "Split #{index + 1} amount must be greater than $0" unless amount_cents.positive?

            split_attributes(
              category,
              amount_cents,
              category_name: split[:category_name],
              stack_key: split[:stack_key],
              notes: split[:notes],
              metadata: split[:metadata]
            )
          rescue TypeError, ArgumentError => e
            raise e if e.message.start_with?("Split ") || e.message.include?("Budget category")

            raise ArgumentError, "Split #{index + 1} amount must be a number"
          end
          raise ArgumentError, "Transaction splits must equal transaction total" unless splits.sum { |split| split.fetch(:amount_cents) } == total_cents

          splits
        end

        def split_attributes(category, amount_cents, category_name: nil, stack_key: nil, notes: nil, metadata: nil)
          {
            budget_category_id: category&.id,
            category_name: category&.name || bounded_text(category_name, 120).presence,
            stack_key: category&.stack_key || stack_key.to_s.presence_in(BudgetCategory::STACK_KEYS),
            amount_cents: amount_cents,
            notes: bounded_text(notes, 500).presence,
            metadata: metadata.is_a?(Hash) ? metadata : {}
          }
        end

        def normalized_update_splits(draft, values, total_cents:)
          raw = Array(values)
          raise ArgumentError, "Transaction splits are required" if raw.empty?
          raise ArgumentError, "Add no more than #{MAX_SPLITS} transaction splits" if raw.length > MAX_SPLITS

          existing_by_id = draft.transaction_draft_splits.index_by(&:id)
          seen_ids = []
          splits = raw.map.with_index do |value, index|
            split = value.to_h.deep_symbolize_keys
            split_id = normalized_split_id(split[:id])
            existing = existing_by_id[split_id] if split_id
            raise ArgumentError, "Split #{index + 1} does not belong to this transaction review" if split_id && !existing
            raise ArgumentError, "A transaction split can only be included once" if split_id && seen_ids.include?(split_id)

            seen_ids << split_id if split_id
            category = if split.key?(:budget_category_id) || split.key?(:category_id)
              active_category(split[:budget_category_id] || split[:category_id])
            else
              existing&.budget_category
            end
            amount_cents = split.key?(:amount_cents) ? Integer(split.fetch(:amount_cents)) : parsed_amount_cents(split[:amount], message: "Split #{index + 1} amount must be a number")
            raise ArgumentError, "Split #{index + 1} amount must be greater than $0" unless amount_cents.positive?

            {
              id: existing&.id,
              budget_category_id: category&.id,
              category_name: category&.name || (split.key?(:category_name) ? bounded_text(split[:category_name], 120).presence : existing&.category_name),
              stack_key: category&.stack_key || (split.key?(:stack_key) ? split[:stack_key].to_s.presence_in(BudgetCategory::STACK_KEYS) : existing&.stack_key),
              amount_cents: amount_cents,
              notes: split.key?(:notes) ? bounded_text(split[:notes], 500).presence : existing&.notes,
              confidence: existing&.confidence,
              metadata: existing ? existing.metadata : { "human_reviewed_replacement" => true }
            }
          rescue TypeError, ArgumentError => e
            raise e if e.message.match?(/split|budget category/i)

            raise ArgumentError, "Split #{index + 1} amount must be a number"
          end
          raise ArgumentError, "Transaction splits must equal transaction total" unless splits.sum { |split| split.fetch(:amount_cents) } == total_cents

          splits
        end

        def normalized_split_id(value)
          return if value.blank?

          Integer(value)
        rescue ArgumentError, TypeError
          raise ArgumentError, "Transaction split id is invalid"
        end

        def draft_snapshot(draft, lock: false)
          draft.lock! if lock && draft.persisted?
          {
            draft: {
              id: draft.id,
              occurred_on: draft.occurred_on&.iso8601,
              merchant: draft.merchant,
              total_amount_cents: draft.total_amount_cents,
              budget_category_id: draft.budget_category_id,
              source_type: draft.source_type,
              status: draft.status
            },
            splits: draft.transaction_draft_splits.order(:id).map do |split|
              {
                id: split.id,
                budget_category_id: split.budget_category_id,
                category_name: split.budget_category&.name || split.category_name,
                stack_key: split.budget_category&.stack_key || split.stack_key,
                amount_cents: split.amount_cents,
                notes: split.notes.presence,
                confidence: split.confidence,
                metadata: split.metadata || {}
              }
            end
          }
        end

        def resolution_snapshot(draft, lock: false)
          snapshot = draft_snapshot(draft, lock: lock)
          snapshot[:draft][:confirmed_transaction_id] = draft.confirmed_transaction_id
          snapshot[:draft][:matched_transaction_id] = draft.matched_transaction_id
          snapshot[:matches] = draft.transaction_draft_matches.order(:id).map do |match|
            {
              id: match.id,
              household_transaction_id: match.household_transaction_id,
              status: match.status,
              confidence: match.confidence,
              match_reason: match.match_reason
            }
          end
          transaction = draft.confirmed_transaction
          snapshot[:transaction] = transaction && {
            id: transaction.id,
            status: transaction.status,
            occurred_on: transaction.occurred_on.iso8601,
            merchant: transaction.merchant,
            total_amount_cents: transaction.total_amount_cents,
            source_type: transaction.source_type,
            splits: transaction.transaction_splits.order(:id).map do |split|
              { id: split.id, budget_category_id: split.budget_category_id, amount_cents: split.amount_cents, notes: split.notes }
            end
          }
          snapshot
        end

        def verify_after!(predicted, actual)
          return true if comparable_snapshot(predicted) == comparable_snapshot(actual)

          raise ArgumentError, "The transaction review did not match the requested change. Nothing changed."
        end

        def comparable_snapshot(value)
          snapshot = value.deep_stringify_keys
          draft = snapshot.fetch("draft").except("id")
          splits = Array(snapshot.fetch("splits")).map { |split| split.except("id") }
          { "draft" => draft, "splits" => splits }
        end

        def stale_message
          "The transaction review changed before this request finished. Refresh it and try again. Nothing changed."
        end
      end
    end
  end
end
