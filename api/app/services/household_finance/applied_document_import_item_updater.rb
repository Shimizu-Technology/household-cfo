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
          item.update!(attributes)
          sync_applied_record!
          item.update!(metadata: correction_metadata)
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
      cents = item.amount_cents.to_i
      record.update!(
        label: item.label,
        source_type: item.source_type.presence_in(IncomeSource::SOURCE_TYPES) || record.source_type || "other",
        amount_cents: cents,
        cadence: cadence_for(item),
        active: cents.positive?
      )
    end

    def sync_expense_item!
      record = typed_record!(ExpenseItem)
      cents = item.amount_cents.to_i
      record.update!(
        label: item.label,
        stack_key: item.stack_key.presence_in(ExpenseItem::STACK_KEYS) || record.stack_key || "discretionary",
        amount_cents: cents,
        cadence: cadence_for(item),
        active: cents.positive?
      )
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
      record.update!(
        label: item.label,
        goal_type: goal_type.presence_in(Goal::GOAL_TYPES) || record.goal_type || "other",
        target_amount_cents: item.amount_cents.to_i
      )
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
