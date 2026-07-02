module HouseholdFinance
  class TransactionDraftConfirmer
    InvalidDraftCorrection = Class.new(StandardError)
    Result = Struct.new(:success?, :draft, :transaction, :errors, keyword_init: true)

    def initialize(draft, attributes = {})
      @draft = draft
      @attributes = attributes.to_h.symbolize_keys
    end

    def call
      transaction = nil
      ApplicationRecord.transaction do
        draft.with_lock do
          if draft.pending?
            corrected = apply_corrections!
            transaction = create_transaction!
            draft.update!(status: corrected ? "corrected" : "confirmed", confirmed_transaction: transaction)
          end
        end
      end

      return Result.new(success?: true, draft: draft.reload, transaction: transaction, errors: []) if transaction

      Result.new(success?: false, draft: draft.reload, transaction: nil, errors: [ "Transaction draft is not pending" ])
    rescue InvalidDraftCorrection, ArgumentError => e
      Result.new(success?: false, draft: draft.reload, transaction: transaction, errors: [ e.message ])
    rescue ActiveRecord::RecordInvalid => e
      Result.new(success?: false, draft: draft, transaction: transaction, errors: e.record.errors.full_messages)
    end

    private

    attr_reader :draft, :attributes

    def apply_corrections!
      draft.assign_attributes(
        occurred_on: parsed_date(attributes[:occurred_on]) || draft.occurred_on,
        merchant: bounded_text(attributes[:merchant], 120).presence || draft.merchant,
        total_amount_cents: attributes.key?(:amount) ? Money.cents(attributes[:amount]) : draft.total_amount_cents,
        budget_category: selected_category || draft.budget_category
      )
      corrected = draft.changed?
      draft.status = "corrected" if corrected
      draft.save! if draft.changed?
      corrected
    end

    def create_transaction!
      ensure_supported_transaction_date!
      category = transaction_category
      period = annual_budget_manager.current_period_for(draft.occurred_on)
      transaction = draft.household.household_transactions.create!(
        budget_period: period,
        occurred_on: draft.occurred_on,
        merchant: draft.merchant,
        description: draft.raw_input,
        total_amount_cents: draft.total_amount_cents,
        source_type: draft.source_type,
        status: "confirmed",
        metadata: { "draft_id" => draft.id }
      )
      transaction.transaction_splits.create!(budget_category: category, amount_cents: draft.total_amount_cents)
      transaction
    end

    def selected_category
      return nil unless attributes[:budget_category_id].present?

      draft.household.budget_categories.active.find_by(id: attributes[:budget_category_id]) || raise(InvalidDraftCorrection, "Budget category not found")
    end

    def transaction_category
      return draft.budget_category if draft.budget_category&.active?
      return fallback_category if draft.budget_category.nil?

      raise InvalidDraftCorrection, "Budget category not found"
    end

    def fallback_category
      annual_budget_manager.ensure_plan!
      draft.household.budget_categories.active.ordered.first || annual_budget_manager.create_category!(name: "Uncategorized", stack_key: "discretionary")
    end

    def annual_budget_manager
      @annual_budget_manager ||= AnnualBudgetManager.new(draft.household, year: draft.occurred_on.year)
    end

    def ensure_supported_transaction_date!
      return if AnnualBudgetManager.supported_year?(draft.occurred_on.year)

      raise InvalidDraftCorrection, "Transaction date is outside supported budget years"
    end

    def parsed_date(value)
      return nil if value.blank?

      date = Date.iso8601(value.to_s)
      raise InvalidDraftCorrection, "Transaction date is outside supported budget years" unless AnnualBudgetManager.supported_year?(date.year)

      date
    rescue ArgumentError
      nil
    end

    def bounded_text(value, max_length)
      value.to_s.squish.truncate(max_length, omission: "…")
    end
  end
end
