module HouseholdFinance
  class DocumentImportApplier
    MAX_PROFILE_NOTES_LENGTH = 2_000
    PROFILE_NOTES_TRIM_MARKER = "[Older document-derived profile notes trimmed]"

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
      document_import.with_lock do
        next failure("Document import is not ready for review") unless reviewable_for_apply?

        # Document apply is the only flow that locks both rows. Keep this order
        # (import, then household) so future mutations avoid lock-order cycles.
        household.with_lock do
          items = selected_items.to_a
          if items.empty?
            update_import_status!
            next failure("No selected extracted values to apply") if unresolved_items_exist?
          else
            items.each { |item| apply_item!(item) }
            update_import_status!
          end

          Result.new(success: true, import: document_import.reload, applied_count: applied_count, errors: [])
        end
      end
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.join(", "))
    rescue StandardError => e
      failure(e.message)
    end

    private

    attr_reader :document_import, :household, :user, :item_ids, :applied_count

    def reviewable_for_apply?
      document_import.needs_review? || document_import.partially_applied?
    end

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
      record = find_label_record_or_initialize(household.income_sources, item.label, source_type: source_type)
      record.update!(amount_cents: item.amount_cents.to_i, cadence: cadence_for(item), active: item.amount_cents.to_i.positive?)
      record
    end

    def apply_expense_item(item)
      stack_key = item.stack_key.presence_in(ExpenseItem::STACK_KEYS) || "discretionary"
      record = find_label_record_or_initialize(household.expense_items, item.label, stack_key: stack_key)
      record.update!(amount_cents: item.amount_cents.to_i, cadence: cadence_for(item), active: item.amount_cents.to_i.positive?)
      record
    end

    def apply_account(item)
      account_type = item.account_type.presence_in(Account::ACCOUNT_TYPES) || "other"
      record = find_label_record_or_initialize(household.accounts, item.label, account_type: account_type)
      record.update!(balance_cents: item.balance_cents.to_i)
      record
    end

    def apply_debt(item)
      debt_type = item.debt_type.presence_in(Debt::DEBT_TYPES) || "other"
      record = find_label_record_or_initialize(household.debts, item.label, debt_type: debt_type)
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
        find_label_record_or_initialize(household.goals, item.label, goal_type: goal_type)
      end
      record.label = item.label
      record.target_amount_cents = item.amount_cents.to_i
      record.priority = next_goal_priority if record.new_record? && record.priority.to_i.zero?
      record.save!
      record
    end

    def find_label_record_or_initialize(association, label, attributes)
      label_text = label.to_s.squish
      association.where(attributes).where("LOWER(label) = ?", label_text.downcase).first ||
        association.new(attributes.merge(label: label_text))
    end

    def apply_profile_note(item)
      profile = household.household_profile || household.create_household_profile!
      note = [ item.label, item.evidence ].compact_blank.join(" — ").truncate(500, omission: "…")
      existing_notes = profile.notes.to_s.strip
      profile.update!(notes: bounded_profile_notes(existing_notes, note))
      profile
    end

    def bounded_profile_notes(existing_notes, note)
      combined = [ existing_notes.presence, note ].compact.join("\n")
      return combined if combined.length <= MAX_PROFILE_NOTES_LENGTH

      retained_length = MAX_PROFILE_NOTES_LENGTH - PROFILE_NOTES_TRIM_MARKER.length - 1
      [ PROFILE_NOTES_TRIM_MARKER, combined.last(retained_length) ].join("\n")
    end

    def cadence_for(item)
      item.cadence.presence_in(IncomeSource::CADENCES) || "monthly"
    end

    def next_goal_priority
      (household.goals.maximum(:priority) || 0) + 1
    end

    def update_import_status!
      status = reconciled_status
      timestamp = Time.current
      document_import.update!(
        status: status,
        applied_at: status == "applied" || applied_count.positive? ? timestamp : document_import.applied_at,
        applied_by_user: status == "applied" || applied_count.positive? ? user : document_import.applied_by_user,
        metadata: (document_import.metadata || {}).merge("last_applied_count" => applied_count, "last_applied_at" => timestamp.iso8601)
      )
    end

    def reconciled_status
      unapplied_actionable = document_import.items.where(ignored: false, applied_at: nil).exists?
      return "applied" unless unapplied_actionable

      document_import.items.where(ignored: false).where.not(applied_at: nil).exists? ? "partially_applied" : "needs_review"
    end

    def unresolved_items_exist?
      document_import.items.where(ignored: false, applied_at: nil).exists?
    end

    def failure(message)
      Result.new(success: false, import: document_import, applied_count: 0, errors: [ message ])
    end
  end
end
