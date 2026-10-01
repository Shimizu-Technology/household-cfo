require_relative "base"

module HouseholdFinance
  module Operations
    module Transaction
      class DraftCreate < Base
        KEY = "transaction.draft.create"
        VERSION = 1

        private

        def normalize(input)
          occurred_on = parsed_date(input[:occurred_on])
          merchant = bounded_text(input[:merchant], 120)
          raise ArgumentError, "Transaction merchant is required" if merchant.blank?

          total_cents = if input.key?(:amount_cents)
            Integer(input.fetch(:amount_cents))
          else
            parsed_amount_cents(input[:amount])
          end
          raise ArgumentError, "Transaction amount must be greater than $0" unless total_cents.positive?
          source_type = normalized_source_type(input[:source_type])
          category = active_category(input[:budget_category_id] || input[:category_id])
          category ||= suggested_category(merchant, input) unless Array(input[:splits]).any?
          splits = normalized_splits(input[:splits], total_cents: total_cents, fallback_category: category)

          {
            occurred_on: occurred_on.iso8601,
            merchant: merchant,
            amount_cents: total_cents,
            source_type: source_type,
            raw_input: bounded_text(input[:raw_input], ChatMessage::MAX_CONTENT_LENGTH).presence,
            splits: splits,
            year: occurred_on.year
          }
        rescue TypeError, ArgumentError => e
          raise e unless e.message.match?(/invalid value for Integer|can't convert|base specified/)

          raise ArgumentError, "Transaction amount must be a number"
        end

        def subject_for(_input, lock:)
          lock ? household.lock! : household
        end

        def canonical_snapshot(_subject, _input, lock:)
          { draft: nil, splits: [] }
        end

        def predicted_after(_before, input)
          confidence = input.fetch(:source_type) == "manual_ui" ? BigDecimal("1.0") : BigDecimal("0.90")
          {
            draft: {
              id: nil,
              occurred_on: input.fetch(:occurred_on), merchant: input.fetch(:merchant), total_amount_cents: input.fetch(:amount_cents),
              budget_category_id: input.fetch(:splits).first[:budget_category_id], source_type: input.fetch(:source_type), status: "pending"
            },
            splits: input.fetch(:splits).map { |split| split.merge(confidence: confidence) }
          }
        end

        def validate_execution!(_subject, input, prepared:, source:)
          validate_source!(input, source)
        end

        def mutate!(_subject, input, prepared:)
          splits = input.fetch(:splits)
          draft = household.transaction_drafts.create!(
            occurred_on: Date.iso8601(input.fetch(:occurred_on)),
            merchant: input.fetch(:merchant),
            total_amount_cents: input.fetch(:amount_cents),
            budget_category_id: splits.first[:budget_category_id],
            source_type: input.fetch(:source_type),
            status: "pending",
            confidence: input.fetch(:source_type) == "manual_ui" ? BigDecimal("1.0") : BigDecimal("0.90"),
            raw_input: input[:raw_input],
            draft_payload: {
              parser: input.fetch(:source_type) == "manual_chat" ? "mia_structured_transaction_v1" : "manual_transaction_form_v1",
              source: input.fetch(:source_type)
            }
          )
          splits.each do |split|
            draft.transaction_draft_splits.create!(split.except(:budget_category_id).merge(budget_category_id: split[:budget_category_id], confidence: draft.confidence))
          end
          TransactionDraftMatcher.new(draft).call
          draft.reload
        end

        def canonical_after_snapshot(draft, _input, prepared:)
          draft_snapshot(draft.reload)
        end

        def suggested_category(merchant, input)
          suggester = TransactionCategorySuggester.new(household)
          suggestion = suggester.suggest(
            merchant: merchant,
            category_name: input[:category_name],
            stack_key: input[:stack_key],
            text: input[:category_context],
            confidence: BigDecimal("0.90")
          ).category
          suggestion || suggester.recognized_fallback_category(merchant: merchant, text: input[:category_context])
        end
      end
    end
  end
end
