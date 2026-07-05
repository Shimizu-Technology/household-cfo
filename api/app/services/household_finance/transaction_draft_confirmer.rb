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
            HouseholdFinance::DocumentImportStatusReconciler.new(draft.financial_document_import).call if draft.financial_document_import
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
      original_signature = correction_signature
      draft.assign_attributes(
        occurred_on: parsed_date(attributes[:occurred_on]) || draft.occurred_on,
        merchant: bounded_text(attributes[:merchant], 120).presence || draft.merchant,
        total_amount_cents: corrected_amount_cents,
        budget_category: selected_category || draft.budget_category
      )
      draft.save! if draft.changed?
      apply_split_corrections!
      corrected = correction_signature != original_signature
      draft.status = "corrected" if corrected
      draft.save! if draft.changed?
      corrected
    end

    def create_transaction!
      ensure_supported_transaction_date!
      splits = splits_for_confirmation
      period = annual_budget_manager.current_period_for(draft.occurred_on)
      transaction = draft.household.household_transactions.create!(
        budget_period: period,
        source_import: draft.financial_document_import,
        occurred_on: draft.occurred_on,
        merchant: draft.merchant,
        description: draft.raw_input,
        total_amount_cents: draft.total_amount_cents,
        source_type: draft.source_type,
        status: "confirmed",
        metadata: { "draft_id" => draft.id, "document_import_id" => draft.financial_document_import_id }.compact
      )
      splits.each do |split|
        transaction.transaction_splits.create!(budget_category: split.fetch(:budget_category), amount_cents: split.fetch(:amount_cents), notes: split[:notes])
      end
      transaction.validate_split_total!
      remember_merchant_category_rules!(splits)
      transaction
    end

    def corrected_amount_cents
      return draft.total_amount_cents unless attributes[:amount].present?

      cents = Money.cents!(attributes[:amount], message: "Transaction amount must be a number")
      return cents if cents.positive?

      raise InvalidDraftCorrection, "Transaction amount must be greater than $0"
    end

    def selected_category
      return nil unless attributes[:budget_category_id].present?

      @selected_category ||= active_category_for(attributes[:budget_category_id])
    end

    def active_category_for(category_id)
      category = draft.household.budget_categories.find_by(id: category_id)
      raise InvalidDraftCorrection, "Budget category not found" unless category
      raise InvalidDraftCorrection, archived_category_message unless category.active?

      category
    end

    def apply_split_corrections!
      if attributes[:splits].present?
        TransactionDraftUpdater.new(draft, splits: attributes[:splits]).call.tap do |result|
          raise InvalidDraftCorrection, result.errors.to_sentence unless result.success?
        end
      elsif selected_category
        draft.transaction_draft_splits.destroy_all
        draft.transaction_draft_splits.create!(
          budget_category: selected_category,
          amount_cents: draft.total_amount_cents,
          category_name: selected_category.name,
          stack_key: selected_category.stack_key
        )
      elsif draft.transaction_draft_splits.exists? && draft.transaction_draft_splits.sum(:amount_cents) != draft.total_amount_cents
        raise InvalidDraftCorrection, "Transaction splits must equal transaction total"
      end
    end

    def splits_for_confirmation
      splits = if draft.transaction_draft_splits.exists?
        draft.transaction_draft_splits.ordered.map do |split|
          category = split.budget_category
          category ||= category_from_split_name(split)
          category ||= fallback_category
          raise InvalidDraftCorrection, archived_category_message unless category.active?

          { budget_category: category, amount_cents: split.amount_cents, notes: split.notes }
        end
      else
        [ { budget_category: transaction_category, amount_cents: draft.total_amount_cents, notes: nil } ]
      end
      raise InvalidDraftCorrection, "Transaction splits must equal transaction total" unless splits.sum { |split| split.fetch(:amount_cents) } == draft.total_amount_cents

      splits
    end

    def category_from_split_name(split)
      name = bounded_text(split.category_name, 80)
      return if name.blank? || name.match?(/\A(?:uncategorized|needs category)\z/i)

      existing = draft.household.budget_categories.where("LOWER(name) = ?", name.downcase).first
      return existing if existing&.active?
      return annual_budget_manager.restore_category!(existing) if existing

      annual_budget_manager.create_category!(
        name: name,
        stack_key: split.stack_key.presence_in(BudgetCategory::STACK_KEYS) || "discretionary",
        monthly_amount: 0
      )
    end

    def transaction_category
      return draft.budget_category if draft.budget_category&.active?
      return fallback_category if draft.budget_category.nil?

      raise InvalidDraftCorrection, archived_category_message
    end

    def archived_category_message
      "Budget category is archived. Restore it or choose an active category before confirming."
    end

    def fallback_category
      annual_budget_manager.ensure_plan!
      draft.household.budget_categories.active.ordered.first ||
        restore_archived_uncategorized_category ||
        annual_budget_manager.create_category!(name: "Uncategorized", stack_key: "discretionary")
    end

    def restore_archived_uncategorized_category
      category = draft.household.budget_categories.archived.where("LOWER(name) = ?", "uncategorized").ordered.first
      return unless category

      annual_budget_manager.restore_category!(category)
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

    def remember_merchant_category_rules!(splits)
      pattern = MerchantCategoryRule.normalized_pattern(draft.merchant)
      return if pattern.blank?

      splits.group_by { |split| split.fetch(:budget_category) }.each do |category, category_splits|
        next unless category&.active?

        rule = draft.household.merchant_category_rules.find_or_initialize_by(merchant_pattern: pattern, budget_category: category)
        rule.confidence = [ BigDecimal("0.95"), (rule.confidence || BigDecimal("0.80")).to_d + BigDecimal("0.03") ].min
        rule.source = "user_confirmed"
        rule.times_confirmed = rule.times_confirmed.to_i + category_splits.length
        rule.last_confirmed_at = Time.current
        rule.active = true
        rule.save!
      end
    end

    def correction_signature
      [
        draft.occurred_on,
        draft.merchant,
        draft.total_amount_cents,
        draft.budget_category_id,
        draft.transaction_draft_splits.order(:id).map { |split| [ split.budget_category_id, split.amount_cents, split.category_name, split.stack_key, split.notes ] }
      ]
    end

    def bounded_text(value, max_length)
      value.to_s.squish.truncate(max_length, omission: "…")
    end
  end
end
