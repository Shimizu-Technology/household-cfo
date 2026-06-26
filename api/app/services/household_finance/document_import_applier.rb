module HouseholdFinance
  class DocumentImportApplier
    Result = Data.define(:success, :import, :applied_count, :errors) do
      def success?
        success == true
      end
    end

    def initialize(document_import, user:, item_ids: nil)
      @document_import = document_import
      @household = document_import.household
      @user = user
      @item_ids = Array(item_ids).compact_blank.map(&:to_i).presence
      @applied_count = 0
    end

    def call
      return failure("Document import is not ready for review") unless document_import.needs_review? || document_import.partially_applied?

      document_import.with_lock do
        items = selected_items.to_a
        return failure("No selected extracted values to apply") if items.empty?

        items.each { |item| apply_item!(item) }
        update_import_status!
      end

      Result.new(success: true, import: document_import.reload, applied_count: applied_count, errors: [])
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.join(", "))
    rescue StandardError => e
      failure(e.message)
    end

    private

    attr_reader :document_import, :household, :user, :item_ids, :applied_count

    def selected_items
      scope = document_import.items.apply_candidates.order(:id)
      scope = scope.where(id: item_ids) if item_ids.present?
      scope
    end

    def apply_item!(item)
      record = case item.target_type
      when "income_source"
        apply_income_source(item)
      when "expense_item"
        apply_expense_item(item)
      when "account"
        apply_account(item)
      when "debt"
        apply_debt(item)
      when "goal"
        apply_goal(item)
      when "profile_note"
        apply_profile_note(item)
      else
        raise ActiveRecord::RecordInvalid, item
      end

      item.update!(
        applied_at: Time.current,
        applied_by_user: user,
        applied_record: record,
        selected: true,
        ignored: false,
        metadata: (item.metadata || {}).merge("applied_from_document_import_id" => document_import.id)
      )
      @applied_count += 1
    end

    def apply_income_source(item)
      source_type = item.source_type.presence_in(IncomeSource::SOURCE_TYPES) || "other"
      record = household.income_sources.find_or_initialize_by(label: item.label, source_type: source_type)
      record.update!(amount_cents: item.amount_cents.to_i, cadence: cadence_for(item), active: item.amount_cents.to_i.positive?)
      record
    end

    def apply_expense_item(item)
      stack_key = item.stack_key.presence_in(ExpenseItem::STACK_KEYS) || "discretionary"
      record = household.expense_items.find_or_initialize_by(label: item.label, stack_key: stack_key)
      record.update!(amount_cents: item.amount_cents.to_i, cadence: cadence_for(item), active: item.amount_cents.to_i.positive?)
      record
    end

    def apply_account(item)
      account_type = item.account_type.presence_in(Account::ACCOUNT_TYPES) || "other"
      record = household.accounts.find_or_initialize_by(label: item.label, account_type: account_type)
      record.update!(balance_cents: item.balance_cents.to_i)
      record
    end

    def apply_debt(item)
      debt_type = item.debt_type.presence_in(Debt::DEBT_TYPES) || "other"
      record = household.debts.find_or_initialize_by(label: item.label, debt_type: debt_type)
      balance_cents = item.balance_cents || record.balance_cents || 0
      payment_cents = item.payment_cents || record.minimum_payment_cents || 0
      record.update!(balance_cents: balance_cents, minimum_payment_cents: payment_cents)
      record
    end

    def apply_goal(item)
      goal_type = item.metadata.is_a?(Hash) ? item.metadata["goal_type"].to_s : ""
      goal_type = "other" unless goal_type.in?(Goal::GOAL_TYPES)
      record = if goal_type.in?(%w[runway transition])
        household.goals.find_or_initialize_by(goal_type: goal_type)
      else
        household.goals.where(goal_type: goal_type, label: item.label).first_or_initialize
      end
      record.label = item.label
      record.target_amount_cents = item.amount_cents.to_i
      record.priority = next_goal_priority if record.new_record? && record.priority.to_i.zero?
      record.save!
      record
    end

    def apply_profile_note(item)
      profile = household.household_profile || household.create_household_profile!
      note = [ item.label, item.evidence ].compact_blank.join(" — ").truncate(500, omission: "…")
      existing_notes = profile.notes.to_s.strip
      profile.update!(notes: [ existing_notes.presence, note ].compact.join("\n"))
      profile
    end

    def cadence_for(item)
      item.cadence.presence_in(IncomeSource::CADENCES) || "monthly"
    end

    def next_goal_priority
      (household.goals.maximum(:priority) || 0) + 1
    end

    def update_import_status!
      total_applyable = document_import.items.where(ignored: false).count
      total_applied = document_import.items.where.not(applied_at: nil).count
      status = total_applied >= total_applyable ? "applied" : "partially_applied"
      document_import.update!(
        status: status,
        applied_at: Time.current,
        applied_by_user: user,
        metadata: (document_import.metadata || {}).merge("last_applied_count" => applied_count, "last_applied_at" => Time.current.iso8601)
      )
    end

    def failure(message)
      Result.new(success: false, import: document_import, applied_count: 0, errors: [ message ])
    end
  end
end
