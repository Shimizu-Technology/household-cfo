module HouseholdFinance
  class TransactionDraftConfirmer
    InvalidDraftCorrection = Class.new(StandardError)
    # The purchase looks like one she already has. Confirming would count it
    # twice, so nothing changes until she says whether it is the same purchase
    # (accept the match) or a different one (confirm with different_purchase).
    class PossibleDuplicate < ArgumentError
      attr_reader :matches

      def initialize(message, matches)
        super(message)
        @matches = matches
      end
    end
    MERCHANT_RULE_INITIAL_CONFIDENCE = BigDecimal("0.83")
    MERCHANT_RULE_UPSERT_SQL = Arel.sql(<<~SQL.squish)
      confidence = LEAST(0.95, merchant_category_rules.confidence + 0.03),
      source = EXCLUDED.source,
      times_confirmed = merchant_category_rules.times_confirmed + EXCLUDED.times_confirmed,
      last_confirmed_at = EXCLUDED.last_confirmed_at,
      active = EXCLUDED.active,
      updated_at = EXCLUDED.updated_at
    SQL
    Result = Struct.new(:success?, :draft, :transaction, :errors, :possible_matches, keyword_init: true)

    def self.possible_duplicate_message(matches, today: Date.current)
      first = matches.first.household_transaction
      others = matches.length - 1
      date = first.occurred_on.year == today.year ? first.occurred_on.strftime("%b %-d") : first.occurred_on.strftime("%b %-d, %Y")
      amount = ActiveSupport::NumberHelper.number_to_currency(Money.dollars(first.total_amount_cents))
      also = others.positive? ? " or #{others} other #{'purchase'.pluralize(others)}" : ""
      "This looks like #{store_name(first.merchant)} on #{date} (#{amount})#{also}, which you already have. Is it the same purchase or a different one? Nothing was added to your spending."
    end

    # The store as she knows it, without bank wording ("Purchase authorized on 06/23 … Tamuning Gum").
    def self.store_name(merchant)
      SpendingPatterns::MerchantName.call(merchant).presence || merchant
    end

    # different_purchase: she answered "Different purchase" to "Same purchase as …?".
    def initialize(draft, attributes = {}, reconcile_import: true, different_purchase: false)
      @draft = draft
      @attributes = attributes.to_h.symbolize_keys
      @reconcile_import = reconcile_import
      @different_purchase = different_purchase == true
    end

    def call
      transaction = nil
      # A savepoint, so a refusal leaves nothing changed even inside a caller's transaction.
      ApplicationRecord.transaction(requires_new: true) do
        draft.with_lock do
          if draft.financial_source_event_id.present?
            raise ArgumentError, "Review this statement row in Statements before adding it to your spending."
          end
          if draft.pending?
            corrected = apply_corrections!
            settle_possible_duplicates!
            transaction = create_transaction!
            draft.update!(status: corrected ? "corrected" : "confirmed", confirmed_transaction: transaction)
            if reconcile_import && draft.financial_document_import
              HouseholdFinance::DocumentImportStatusReconciler.new(draft.financial_document_import).call
            end
          end
        end
      end

      return Result.new(success?: true, draft: draft.reload, transaction: transaction, errors: []) if transaction

      Result.new(success?: false, draft: draft.reload, transaction: nil, errors: [ "Transaction draft is not pending" ])
    rescue PossibleDuplicate => e
      keep_for_review!
      Result.new(success?: false, draft: draft.reload, transaction: nil, errors: [ e.message ], possible_matches: e.matches)
    rescue InvalidDraftCorrection, ArgumentError => e
      Result.new(success?: false, draft: draft.reload, transaction: transaction, errors: [ e.message ])
    rescue ActiveRecord::RecordInvalid => e
      Result.new(success?: false, draft: draft, transaction: transaction, errors: e.record.errors.full_messages)
    end

    private

    attr_reader :draft, :attributes, :reconcile_import, :different_purchase

    # Look again just before it counts: a bank line approved since she logged
    # this, or a corrected amount, date or merchant, can make it match a
    # purchase she already has. Matches she already rejected stay rejected.
    def settle_possible_duplicates!
      TransactionDraftMatcher.new(draft.reload).call
      proposed = draft.transaction_draft_matches.proposed.best_first.includes(:household_transaction).to_a
      return if proposed.empty?

      unless different_purchase
        raise PossibleDuplicate.new(self.class.possible_duplicate_message(proposed), proposed.map { |match| possible_match_payload(match) })
      end

      # She said it is a different purchase. Keep her answer so the same
      # suggestion is not asked again if this purchase is reopened.
      draft.transaction_draft_matches.proposed.update_all(status: "rejected", updated_at: Time.current)
    end

    # Refused, but her correction is hers to keep: save it on the purchase,
    # which stays pending, and keep the suggestions so its card can ask
    # "Same purchase as …?". Nothing counts. A caller's own transaction (an
    # operation, a group confirm) can still roll this back; the confirm
    # endpoint then saves the correction through transaction.draft.update.
    def keep_for_review!
      draft.reload
      ApplicationRecord.transaction(requires_new: true) do
        draft.with_lock do
          next unless draft.pending?

          if corrections_requested?
            apply_corrections!(keep_pending: true)
            # Suggestions for the amount she corrected away no longer apply.
            draft.transaction_draft_matches.proposed.destroy_all
          end
          TransactionDraftMatcher.new(draft.reload).call
        end
      end
    rescue InvalidDraftCorrection, ArgumentError, ActiveRecord::RecordInvalid => e
      Rails.logger.warn("Possible duplicate kept without its correction draft_id=#{draft.id}: #{e.class}: #{e.message}")
    end

    def corrections_requested?
      attributes.slice(:occurred_on, :merchant, :amount, :budget_category_id, :splits).values.any?(&:present?)
    end

    def possible_match_payload(match)
      transaction = match.household_transaction
      { transaction_id: transaction.id, merchant: transaction.merchant, store_name: self.class.store_name(transaction.merchant), occurred_on: transaction.occurred_on.iso8601,
        amount_cents: transaction.total_amount_cents, confidence: match.confidence&.to_f }
    end

    # keep_pending: save her correction on a purchase that is not being confirmed.
    def apply_corrections!(keep_pending: false)
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
      draft.status = "corrected" if corrected && !keep_pending
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
        financial_source_event: draft.financial_source_event,
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
        TransactionDraftUpdater.new(draft, { splits: attributes[:splits] }, refresh_matches: false).call.tap do |result|
          raise InvalidDraftCorrection, result.errors.to_sentence unless result.success?
        end
      elsif selected_category
        if attributes[:amount].present? && draft.transaction_draft_splits.one?
          draft.transaction_draft_splits.sole.update!(amount_cents: draft.total_amount_cents)
        end
        TransactionDraftUpdater.new(draft, { budget_category_id: selected_category.id }, refresh_matches: false).call.tap do |result|
          raise InvalidDraftCorrection, result.errors.to_sentence unless result.success?
        end
      elsif draft.transaction_draft_splits.exists? && draft.transaction_draft_splits.sum(:amount_cents) != draft.total_amount_cents
        if attributes[:amount].present? && draft.transaction_draft_splits.one?
          draft.transaction_draft_splits.sole.update!(amount_cents: draft.total_amount_cents)
        else
          raise InvalidDraftCorrection, "Transaction splits must equal transaction total"
        end
      end
    end

    def splits_for_confirmation
      splits = if draft.transaction_draft_splits.exists?
        draft.transaction_draft_splits.ordered.map do |split|
          category = split.budget_category
          if draft.financial_document_import_id.present? && category.nil?
            raise InvalidDraftCorrection, "Choose a category for every receipt or document split before confirming."
          end
          category ||= category_from_split_name(split)
          raise InvalidDraftCorrection, "Choose a budget category before confirming this transaction" unless category
          raise InvalidDraftCorrection, archived_category_message unless category.active?
          raise InvalidDraftCorrection, placeholder_category_message if placeholder_category?(category)

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

      if (existing = budget_category_named(name))
        return active_or_restored_category(existing)
      end

      create_category_from_split_name!(name, split.stack_key)
    end

    def create_category_from_split_name!(name, stack_key)
      annual_budget_manager.create_category!(
        name: name,
        stack_key: stack_key.presence_in(BudgetCategory::STACK_KEYS) || "discretionary",
        monthly_amount: 0
      )
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      existing = budget_category_named(name)
      raise unless existing

      active_or_restored_category(existing)
    end

    def budget_category_named(name)
      draft.household.budget_categories.where("LOWER(name) = ?", name.downcase).first
    end

    def active_or_restored_category(category)
      return category if category.active?

      annual_budget_manager.restore_category!(category)
    end

    def transaction_category
      if draft.budget_category&.active?
        raise InvalidDraftCorrection, placeholder_category_message if placeholder_category?(draft.budget_category)

        return draft.budget_category
      end
      raise InvalidDraftCorrection, "Choose a budget category before confirming this transaction" if draft.budget_category.nil?

      raise InvalidDraftCorrection, archived_category_message
    end

    def archived_category_message
      "Budget category is archived. Restore it or choose an active category before confirming."
    end

    def placeholder_category?(category)
      category.name.match?(/\A(?:uncategorized|needs category)\z/i)
    end

    def placeholder_category_message
      "Choose a specific budget category before confirming this transaction"
    end

    def annual_budget_manager
      @annual_budget_manager ||= AnnualBudgetManager.new(draft.household, year: draft.occurred_on.year)
    end

    def ensure_supported_transaction_date!
      raise InvalidDraftCorrection, "Transaction date cannot be in the future" if draft.occurred_on > Date.current
      return if AnnualBudgetManager.supported_year?(draft.occurred_on.year)

      raise InvalidDraftCorrection, "Transaction date is outside supported budget years"
    end

    def parsed_date(value)
      return nil if value.blank?

      date = Date.iso8601(value.to_s)
      raise InvalidDraftCorrection, "Transaction date is outside supported budget years" unless AnnualBudgetManager.supported_year?(date.year)
      raise InvalidDraftCorrection, "Transaction date cannot be in the future" if date > Date.current

      date
    rescue ArgumentError
      nil
    end

    def remember_merchant_category_rules!(splits)
      pattern = MerchantCategoryRule.normalized_pattern(draft.merchant)
      return if pattern.blank?

      rows = merchant_category_rule_rows(pattern, splits)
      return if rows.empty?

      MerchantCategoryRule.upsert_all(
        rows,
        unique_by: :index_merchant_rules_on_household_pattern_category,
        on_duplicate: MERCHANT_RULE_UPSERT_SQL
      )
    end

    def merchant_category_rule_rows(pattern, splits)
      now = Time.current
      splits.group_by { |split| split.fetch(:budget_category) }.filter_map do |category, category_splits|
        next unless category&.active?

        {
          household_id: draft.household_id,
          financial_generation: draft.financial_generation,
          budget_category_id: category.id,
          merchant_pattern: pattern,
          confidence: MERCHANT_RULE_INITIAL_CONFIDENCE,
          source: "user_confirmed",
          times_confirmed: category_splits.length,
          last_confirmed_at: now,
          active: true,
          metadata: {},
          created_at: now,
          updated_at: now
        }
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
