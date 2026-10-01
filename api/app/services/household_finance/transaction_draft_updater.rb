module HouseholdFinance
  class TransactionDraftUpdater
    InvalidDraftUpdate = Class.new(StandardError)
    Result = Data.define(:success, :draft, :errors) do
      def success?
        success == true
      end
    end

    def initialize(draft, attributes = {}, refresh_matches: true)
      @draft = draft
      @attributes = attributes.to_h.deep_symbolize_keys
      @household = draft.household
      @refresh_matches = refresh_matches
    end

    def call
      draft.with_lock do
        raise InvalidDraftUpdate, "Transaction draft is not pending" unless draft.pending?

        draft.assign_attributes(draft_attributes)
        draft.save!
        replace_splits! if attributes.key?(:splits)
        normalize_single_category! if attributes[:budget_category_id].present? && !attributes.key?(:splits)
        validate_split_total!
        refresh_match_candidates! if refresh_matches
      end
      Result.new(success: true, draft: draft.reload, errors: [])
    rescue InvalidDraftUpdate, ArgumentError => e
      Result.new(success: false, draft: draft.reload, errors: [ e.message ])
    rescue ActiveRecord::RecordInvalid => e
      Result.new(success: false, draft: draft.reload, errors: e.record.errors.full_messages)
    end

    private

    attr_reader :draft, :attributes, :household, :refresh_matches

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

      existing_by_id = draft.transaction_draft_splits.index_by(&:id)
      normalized = splits.map.with_index { |split, index| normalized_split(split, index: index, existing_by_id: existing_by_id) }
      retained_ids = normalized.filter_map { |split| split[:id] }
      raise InvalidDraftUpdate, "A transaction split can only be included once" unless retained_ids.uniq.length == retained_ids.length
      raise InvalidDraftUpdate, "Transaction splits must equal transaction total" unless normalized.sum { |split| split.fetch(:amount_cents) } == draft.total_amount_cents

      draft.transaction_draft_splits.where.not(id: retained_ids).destroy_all
      normalized.each do |split|
        attributes = split.except(:id)
        if split[:id]
          existing_by_id.fetch(split[:id]).update!(attributes)
        else
          draft.transaction_draft_splits.create!(attributes)
        end
      end
      persisted_splits = draft.transaction_draft_splits.order(:id).to_a
      stable_primary = persisted_splits.find { |split| split.budget_category_id == draft.budget_category_id } || persisted_splits.first
      draft.update!(budget_category: stable_primary&.budget_category)
    end

    def normalize_single_category!
      category = selected_category(attributes[:budget_category_id])
      splits = draft.transaction_draft_splits.order(:id).to_a
      if splits.many?
        raise InvalidDraftUpdate, "This review has multiple category splits. Edit each split category so the receipt or statement amounts stay intact."
      end
      split = splits.first
      if split
        split.update!(budget_category: category, category_name: category.name, stack_key: category.stack_key)
      else
        draft.transaction_draft_splits.create!(
          budget_category: category,
          amount_cents: draft.total_amount_cents,
          category_name: category.name,
          stack_key: category.stack_key,
          metadata: { "human_reviewed_replacement" => true }
        )
      end
      draft.update!(budget_category: category)
    end

    def normalized_split(raw_split, index:, existing_by_id:)
      split = raw_split.is_a?(Hash) ? raw_split.symbolize_keys : {}
      split_id = integer_or_nil(split[:id])
      existing = existing_by_id[split_id] if split_id
      raise InvalidDraftUpdate, "Split #{index + 1} does not belong to this transaction review" if split_id && !existing
      category = if split.key?(:budget_category_id)
        selected_category(split[:budget_category_id]) if split[:budget_category_id].present?
      else
        existing&.budget_category
      end
      amount_cents = parsed_amount_cents(split[:amount])
      raise InvalidDraftUpdate, "Split #{index + 1} amount must be greater than $0" unless amount_cents.positive?

      {
        id: existing&.id,
        budget_category: category,
        amount_cents: amount_cents,
        category_name: category&.name || (split.key?(:category_name) ? bounded_text(split[:category_name], 120).presence : existing&.category_name),
        stack_key: category&.stack_key || (split.key?(:stack_key) ? split[:stack_key].to_s.presence_in(BudgetCategory::STACK_KEYS) : existing&.stack_key),
        notes: split.key?(:notes) ? bounded_text(split[:notes], 500).presence : existing&.notes,
        confidence: existing&.confidence,
        metadata: existing ? existing.metadata : { "human_reviewed_replacement" => true }
      }
    end

    def integer_or_nil(value)
      return if value.blank?

      Integer(value)
    rescue ArgumentError, TypeError
      raise InvalidDraftUpdate, "Transaction split id is invalid"
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
      raise InvalidDraftUpdate, "Transaction date cannot be in the future" if date > Date.current

      date
    rescue ArgumentError
      raise InvalidDraftUpdate, "Transaction date is invalid"
    end

    def parsed_amount_cents(value)
      cents = Money.cents!(value, message: "Transaction amount must be a number")
      raise InvalidDraftUpdate, "Transaction amount must be greater than $0" unless cents.positive?

      cents
    end

    def bounded_text(value, max_length)
      value.to_s.squish.truncate(max_length, omission: "…")
    end
  end
end
