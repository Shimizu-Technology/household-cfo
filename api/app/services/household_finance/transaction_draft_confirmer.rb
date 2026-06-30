module HouseholdFinance
  class TransactionDraftConfirmer
    Result = Struct.new(:success?, :draft, :transaction, :errors, keyword_init: true)

    def initialize(draft, attributes = {})
      @draft = draft
      @attributes = attributes.to_h.symbolize_keys
    end

    def call
      return Result.new(success?: false, draft: draft, errors: [ "Transaction draft is not pending" ]) unless draft.pending?

      transaction = nil
      ApplicationRecord.transaction do
        apply_corrections!
        transaction = create_transaction!
        draft.update!(status: "confirmed", confirmed_transaction: transaction)
      end

      Result.new(success?: true, draft: draft.reload, transaction: transaction, errors: [])
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
      draft.status = "corrected" if draft.changed?
      draft.save!
    end

    def create_transaction!
      category = draft.budget_category || fallback_category
      period = AnnualBudgetManager.new(draft.household, year: draft.occurred_on.year).current_period_for(draft.occurred_on)
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

      draft.household.budget_categories.find(attributes[:budget_category_id])
    end

    def fallback_category
      AnnualBudgetManager.new(draft.household, year: draft.occurred_on.year).ensure_plan!
      draft.household.budget_categories.active.ordered.first || AnnualBudgetManager.new(draft.household, year: draft.occurred_on.year).create_category!(name: "Uncategorized", stack_key: "discretionary")
    end

    def parsed_date(value)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def bounded_text(value, max_length)
      value.to_s.squish.truncate(max_length, omission: "…")
    end
  end
end
