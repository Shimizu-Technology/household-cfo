module HouseholdFinance
  class TransactionDraftUpdater
    InvalidDraftUpdate = Class.new(StandardError)
    Result = Data.define(:success, :draft, :errors) do
      def success?
        success == true
      end
    end

    def initialize(draft, attributes = {})
      @draft = draft
      @attributes = attributes.to_h.deep_symbolize_keys
      @household = draft.household
    end

    def call
      draft.with_lock do
        raise InvalidDraftUpdate, "Transaction draft is not pending" unless draft.pending?

        draft.assign_attributes(draft_attributes)
        draft.save!
        replace_splits! if attributes.key?(:splits)
        normalize_single_category! if attributes[:budget_category_id].present? && !attributes.key?(:splits)
        validate_split_total!
        refresh_match_candidates!
      end
      Result.new(success: true, draft: draft.reload, errors: [])
    rescue InvalidDraftUpdate, ArgumentError => e
      Result.new(success: false, draft: draft.reload, errors: [ e.message ])
    rescue ActiveRecord::RecordInvalid => e
      Result.new(success: false, draft: draft.reload, errors: e.record.errors.full_messages)
    end

    private

    attr_reader :draft, :attributes, :household

    def draft_attributes
      {}.tap do |payload|
        payload[:occurred_on] = parsed_date(attributes[:occurred_on]) if attributes[:occurred_on].present?
        payload[:merchant] = bounded_text(attributes[:merchant], 120) if attributes.key?(:merchant) && attributes[:merchant].present?
        payload[:total_amount_cents] = parsed_amount_cents(attributes[:amount]) if attributes[:amount].present?
        payload[:budget_category] = selected_category(attributes[:budget_category_id]) if attributes[:budget_category_id].present?
      end
    end

    def replace_splits!
      splits = Array(attributes[:splits]).first(DocumentTransactionDraftPersister::MAX_SPLITS)
      raise InvalidDraftUpdate, "Transaction splits are required" if splits.empty?

      normalized = splits.map.with_index { |split, index| normalized_split(split, index: index) }
      raise InvalidDraftUpdate, "Transaction splits must equal transaction total" unless normalized.sum { |split| split.fetch(:amount_cents) } == draft.total_amount_cents

      draft.transaction_draft_splits.destroy_all
      normalized.each do |split|
        draft.transaction_draft_splits.create!(split)
      end
      draft.update!(budget_category: draft.transaction_draft_splits.order(:id).first&.budget_category)
    end

    def normalize_single_category!
      category = selected_category(attributes[:budget_category_id])
      split = draft.transaction_draft_splits.order(:id).first
      if split
        split.update!(budget_category: category, category_name: category.name, stack_key: category.stack_key)
      else
        draft.transaction_draft_splits.create!(
          budget_category: category,
          amount_cents: draft.total_amount_cents,
          category_name: category.name,
          stack_key: category.stack_key
        )
      end
      draft.update!(budget_category: category)
    end

    def normalized_split(raw_split, index:)
      split = raw_split.is_a?(Hash) ? raw_split.symbolize_keys : {}
      category = selected_category(split[:budget_category_id]) if split[:budget_category_id].present?
      amount_cents = parsed_amount_cents(split[:amount])
      raise InvalidDraftUpdate, "Split #{index + 1} amount must be greater than $0" unless amount_cents.positive?

      {
        budget_category: category,
        amount_cents: amount_cents,
        category_name: bounded_text(split[:category_name], 120).presence || category&.name,
        stack_key: split[:stack_key].to_s.presence_in(BudgetCategory::STACK_KEYS) || category&.stack_key,
        notes: bounded_text(split[:notes], 500),
        confidence: decimal_or_nil(split[:confidence]),
        metadata: split[:metadata].is_a?(Hash) ? split[:metadata] : {}
      }
    end

    def validate_split_total!
      return unless draft.transaction_draft_splits.exists?
      return if draft.transaction_draft_splits.sum(:amount_cents) == draft.total_amount_cents

      raise InvalidDraftUpdate, "Transaction splits must equal transaction total"
    end

    def refresh_match_candidates!
      draft.transaction_draft_matches.proposed.destroy_all
      TransactionDraftMatcher.new(draft).call
    end

    def selected_category(category_id)
      category = household.budget_categories.find_by(id: category_id)
      raise InvalidDraftUpdate, "Budget category not found" unless category
      raise InvalidDraftUpdate, "Budget category is archived. Restore it or choose an active category before confirming." unless category.active?

      category
    end

    def parsed_date(value)
      date = Date.iso8601(value.to_s)
      raise InvalidDraftUpdate, "Transaction date is outside supported budget years" unless AnnualBudgetManager.supported_year?(date.year)

      date
    rescue ArgumentError
      raise InvalidDraftUpdate, "Transaction date is invalid"
    end

    def parsed_amount_cents(value)
      cents = Money.cents!(value, message: "Transaction amount must be a number")
      raise InvalidDraftUpdate, "Transaction amount must be greater than $0" unless cents.positive?

      cents
    end

    def decimal_or_nil(value)
      return if value.blank?

      number = BigDecimal(value.to_s)
      return if number.negative?

      [ number, 1 ].min
    rescue ArgumentError
      nil
    end

    def bounded_text(value, max_length)
      value.to_s.squish.truncate(max_length, omission: "…")
    end
  end
end
