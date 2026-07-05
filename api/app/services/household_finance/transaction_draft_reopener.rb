module HouseholdFinance
  class TransactionDraftReopener
    Result = Data.define(:success, :draft, :errors) do
      def success?
        success == true
      end
    end

    def initialize(draft)
      @draft = draft
    end

    def call
      ApplicationRecord.transaction do
        draft.with_lock do
          raise ArgumentError, "Transaction draft is already pending" if draft.pending?

          case draft.status
          when "confirmed", "corrected"
            reopen_confirmed_draft!
          when "matched"
            reopen_matched_draft!
          when "ignored"
            draft.update!(status: "pending")
          else
            raise ArgumentError, "Transaction draft cannot be reopened"
          end
        end
        HouseholdFinance::DocumentImportStatusReconciler.new(draft.financial_document_import).call if draft.financial_document_import
      end

      Result.new(success: true, draft: draft.reload, errors: [])
    rescue ArgumentError, ActiveRecord::RecordInvalid => e
      Result.new(success: false, draft: draft.reload, errors: [ e.message ])
    end

    private

    attr_reader :draft

    def reopen_confirmed_draft!
      transaction = draft.confirmed_transaction
      raise ArgumentError, "Confirmed transaction not found" unless transaction

      transaction.lock!
      raise ArgumentError, "Confirmed transaction belongs to another household" unless transaction.household_id == draft.household_id
      raise ArgumentError, "Undo matched statement rows before reopening this confirmed transaction" if transaction_claimed_by_other_drafts?(transaction)

      forget_merchant_category_rules!(transaction)
      transaction.update!(
        status: "ignored",
        metadata: (transaction.metadata || {}).merge(
          "voided_by_transaction_draft_id" => draft.id,
          "voided_at" => Time.current.iso8601,
          "void_reason" => "draft_reopened"
        )
      )
      draft.update!(status: "pending", confirmed_transaction: nil, matched_transaction: nil)
    end

    def reopen_matched_draft!
      draft.transaction_draft_matches.update_all(status: "proposed", updated_at: Time.current)
      draft.update!(status: "pending", matched_transaction: nil)
    end

    def forget_merchant_category_rules!(transaction)
      pattern = MerchantCategoryRule.normalized_pattern(draft.merchant)
      return if pattern.blank?

      transaction.transaction_splits.group(:budget_category_id).count.each do |category_id, split_count|
        rule = MerchantCategoryRule.find_by(household_id: draft.household_id, merchant_pattern: pattern, budget_category_id: category_id)
        next unless rule

        rule.with_lock do
          next_count = [ rule.times_confirmed - split_count, 0 ].max
          rule.update!(
            active: next_count.positive?,
            times_confirmed: next_count,
            confidence: next_count.positive? ? [ rule.confidence - (BigDecimal("0.03") * split_count), BigDecimal("0.35") ].max : BigDecimal("0.35")
          )
        end
      end
    end

    def transaction_claimed_by_other_drafts?(transaction)
      draft.household.transaction_drafts
        .where(matched_transaction: transaction, status: "matched")
        .where.not(id: draft.id)
        .exists? || TransactionDraftMatch.accepted
          .joins(:transaction_draft)
          .where(household_transaction: transaction)
          .where(transaction_drafts: { household_id: draft.household_id })
          .where.not(transaction_draft_id: draft.id)
          .exists?
    end
  end
end
