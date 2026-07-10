module HouseholdFinance
  class MiaTransactionDraftEditor
    Result = Data.define(:success, :draft, :response, :errors) do
      def success?
        success == true
      end
    end

    def initialize(household, command:)
      @household = household
      @command = command.to_h.deep_symbolize_keys
    end

    def call
      draft = household.transaction_drafts.pending.includes(transaction_draft_splits: :budget_category).find(command.fetch(:draft_id).to_i)
      before = snapshot(draft)
      attributes = update_attributes(draft)
      return failure(draft, "Tell me what to change on that pending transaction review. Nothing changed.") if attributes.empty?

      update = TransactionDraftUpdater.new(draft, attributes).call
      return Result.new(success: false, draft: update.draft, response: update.errors.to_sentence, errors: update.errors) unless update.success?

      updated_draft = update.draft
      changes = change_descriptions(before, snapshot(updated_draft))
      response = if changes.empty?
        "That pending #{updated_draft.merchant} review already has those details. Actuals did not change."
      else
        "I updated the pending #{updated_draft.merchant} review: #{changes.to_sentence}. It is still waiting for your confirmation, and actuals did not change."
      end
      Result.new(success: true, draft: updated_draft, response: response, errors: [])
    rescue ActiveRecord::RecordNotFound
      failure(nil, "I could not find that pending transaction review. Nothing changed; open the review card or tell me the merchant again.")
    rescue KeyError, ArgumentError => e
      failure(nil, "#{e.message}. Nothing changed.")
    end

    private

    attr_reader :household, :command

    def update_attributes(draft)
      {}.tap do |attributes|
        attributes[:occurred_on] = command[:occurred_on] if command[:occurred_on].present?
        attributes[:merchant] = command[:merchant] if command[:merchant].present?
        attributes[:amount] = command[:amount] if command[:amount].present?

        category_id = resolved_category_id(command[:category_id], command[:category_name])
        attributes[:budget_category_id] = category_id if category_id

        explicit_splits = normalized_splits(command[:splits])
        if explicit_splits.any?
          attributes[:splits] = explicit_splits
        elsif command[:amount].present? && draft.transaction_draft_splits.size == 1
          split = draft.transaction_draft_splits.first
          attributes[:splits] = [
            {
              budget_category_id: category_id || split.budget_category_id,
              category_name: category_id ? nil : split.category_name,
              amount: command[:amount]
            }
          ]
        elsif command[:amount].present? && draft.transaction_draft_splits.many?
          raise ArgumentError, "This review has multiple category splits, so tell me the new amount for each split"
        end
      end
    end

    def normalized_splits(values)
      Array(values).first(DocumentTransactionDraftPersister::MAX_SPLITS).map do |raw_split|
        split = raw_split.to_h.deep_symbolize_keys
        category_id = resolved_category_id(split[:category_id], split[:category_name])
        {
          budget_category_id: category_id,
          category_name: split[:category_name],
          amount: split[:amount]
        }.compact
      end
    end

    def resolved_category_id(id, name)
      return if id.to_i.zero? && name.to_s.squish.blank?

      category = if id.to_i.positive?
        household.budget_categories.find_by(id: id.to_i)
      else
        household.budget_categories.find_by("LOWER(name) = ?", name.to_s.squish.downcase)
      end
      raise ArgumentError, "Budget category not found" unless category
      raise ArgumentError, "Budget category is archived. Restore it or choose an active category before confirming." unless category.active?

      category.id
    end

    def snapshot(draft)
      draft.reload
      {
        occurred_on: draft.occurred_on,
        merchant: draft.merchant,
        amount_cents: draft.total_amount_cents,
        category_name: draft.budget_category&.name,
        splits: draft.transaction_draft_splits.ordered.includes(:budget_category).map do |split|
          {
            category_name: split.budget_category&.name || split.category_name,
            amount_cents: split.amount_cents
          }
        end
      }
    end

    def change_descriptions(before, after)
      [] .tap do |changes|
        if before[:occurred_on] != after[:occurred_on]
          changes << "date from #{date_label(before[:occurred_on])} to #{date_label(after[:occurred_on])}"
        end
        if before[:merchant] != after[:merchant]
          changes << "merchant from #{before[:merchant]} to #{after[:merchant]}"
        end
        if before[:amount_cents] != after[:amount_cents]
          changes << "amount from #{money(before[:amount_cents])} to #{money(after[:amount_cents])}"
        end
        if before[:category_name] != after[:category_name]
          changes << "category from #{before[:category_name].presence || 'Uncategorized'} to #{after[:category_name].presence || 'Uncategorized'}"
        elsif before[:splits] != after[:splits]
          changes << "category splits to #{split_label(after[:splits])}"
        end
      end
    end

    def split_label(splits)
      splits.map { |split| "#{split[:category_name].presence || 'Uncategorized'} #{money(split[:amount_cents])}" }.to_sentence
    end

    def date_label(date)
      date.to_date.strftime("%b %-d, %Y")
    end

    def money(cents)
      ActiveSupport::NumberHelper.number_to_currency(Money.dollars(cents), precision: cents.to_i % 100 == 0 ? 0 : 2)
    end

    def failure(draft, message)
      Result.new(success: false, draft: draft, response: message, errors: [ message ])
    end
  end
end
