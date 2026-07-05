# frozen_string_literal: true

module HouseholdFinance
  class AppliedDocumentImportItemUpdater
    Result = Data.define(:success, :item, :errors) do
      def success?
        success == true
      end
    end

    def initialize(item, user:, attributes:)
      @item = item
      @document_import = item.financial_document_import
      @household = document_import.household
      @user = user
      @attributes = attributes.symbolize_keys.except(:selected, :ignored, :target_type)
    end

    def call
      return failure("Applied value is not linked to a saved household record") unless editable_applied_record?

      document_import.with_lock do
        household.with_lock do
          backfill_missing_item_values_from_record!
          item.update!(attributes)
          sync_applied_record!
          item.update!(metadata: correction_metadata)
          HouseholdFinance::DocumentImportStatusReconciler.new(document_import).call
        end
      end

      Result.new(success: true, item: item.reload, errors: [])
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.join(", "))
    rescue StandardError => e
      failure(e.message)
    end

    private

    attr_reader :item, :document_import, :household, :user, :attributes

    def editable_applied_record?
      return false unless item.applied?
      return false unless item.applied_record
      return false unless item.applied_record.respond_to?(:household_id)

      item.applied_record.household_id == household.id
    end

    def backfill_missing_item_values_from_record!
      record = item.applied_record
      case record
      when IncomeSource, ExpenseItem
        item.amount_cents = record.amount_cents if item.amount_cents.nil?
      when Account
        item.balance_cents = record.balance_cents if item.balance_cents.nil?
      when Debt
        item.balance_cents = record.balance_cents if item.balance_cents.nil?
        item.payment_cents = record.minimum_payment_cents if item.payment_cents.nil?
      when Goal
        item.amount_cents = record.target_amount_cents if item.amount_cents.nil?
      end
    end

    def sync_applied_record!
      case item.target_type
      when "income_source"
        sync_income_source!
      when "expense_item"
        sync_expense_item!
      when "account"
        sync_account!
      when "debt"
        sync_debt!
      when "goal"
        sync_goal!
      when "profile_note"
        sync_profile_note!
      else
        raise ActiveRecord::RecordInvalid, item
      end
    end

    def sync_income_source!
      record = typed_record!(IncomeSource)
      attributes = {
        label: item.label,
        source_type: item.source_type.presence_in(IncomeSource::SOURCE_TYPES) || record.source_type || "other",
        cadence: cadence_for(item)
      }
      unless item.amount_cents.nil?
        attributes[:amount_cents] = item.amount_cents
        attributes[:active] = item.amount_cents.positive?
      end
      record.update!(attributes)
    end

    def sync_expense_item!
      record = typed_record!(ExpenseItem)
      attributes = {
        label: item.label,
        stack_key: item.stack_key.presence_in(ExpenseItem::STACK_KEYS) || record.stack_key || "discretionary",
        cadence: cadence_for(item)
      }
      unless item.amount_cents.nil?
        attributes[:amount_cents] = item.amount_cents
        attributes[:active] = item.amount_cents.positive?
      end
      record.update!(attributes)
    end

    def sync_account!
      record = typed_record!(Account)
      attributes = {
        label: item.label,
        account_type: item.account_type.presence_in(Account::ACCOUNT_TYPES) || record.account_type || "other"
      }
      attributes[:balance_cents] = item.balance_cents unless item.balance_cents.nil?
      record.update!(attributes)
    end

    def sync_debt!
      record = typed_record!(Debt)
      attributes = {
        label: item.label,
        debt_type: item.debt_type.presence_in(Debt::DEBT_TYPES) || record.debt_type || "other"
      }
      attributes[:balance_cents] = item.balance_cents unless item.balance_cents.nil?
      attributes[:minimum_payment_cents] = item.payment_cents unless item.payment_cents.nil?
      record.update!(attributes)
    end

    def sync_goal!
      record = typed_record!(Goal)
      goal_type = item.metadata.is_a?(Hash) ? item.metadata["goal_type"].to_s : record.goal_type
      attributes = {
        label: item.label,
        goal_type: goal_type.presence_in(Goal::GOAL_TYPES) || record.goal_type || "other"
      }
      attributes[:target_amount_cents] = item.amount_cents unless item.amount_cents.nil?
      record.update!(attributes)
    end

    def sync_profile_note!
      return unless item.applied_record.is_a?(HouseholdProfile)

      note = [ item.label, item.evidence ].compact_blank.join(" — ").truncate(DocumentImportApplier::MAX_PROFILE_NOTES_LENGTH, omission: "…")
      item.applied_record.update!(notes: note)
    end

    def typed_record!(klass)
      record = item.applied_record
      raise ActiveRecord::RecordInvalid, item unless record.is_a?(klass)

      record
    end

    def cadence_for(item)
      item.cadence.presence_in(IncomeSource::CADENCES) || "monthly"
    end

    def correction_metadata
      (item.metadata || {}).merge(
        "last_corrected_at" => Time.current.iso8601,
        "last_corrected_by_user_id" => user.id
      )
    end

    def failure(message)
      Result.new(success: false, item: item, errors: [ message ])
    end
  end
end
