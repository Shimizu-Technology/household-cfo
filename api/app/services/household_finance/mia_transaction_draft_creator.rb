module HouseholdFinance
  class MiaTransactionDraftCreator
    Result = Data.define(:success, :draft, :errors) do
      def success?
        success == true
      end
    end

    def initialize(household, command:, raw_input:, user:, idempotency_key: nil)
      @household = household
      @command = command.to_h.deep_symbolize_keys
      @raw_input = raw_input.to_s.squish
      @user = user
      @idempotency_key = idempotency_key.presence || SecureRandom.uuid
    end

    def call
      movement = TransactionDraftBuilder.non_expense_movement?(raw_input)
      purchase = TransactionDraftBuilder.explicit_purchase_details(raw_input) if movement
      if movement && purchase.blank?
        raise ArgumentError, "Only already incurred purchases can become transaction reviews"
      end

      safe_command = command.slice(:occurred_on, :merchant, :amount, :category_id, :category_name, :stack_key, :splits, :resolved_message)
      if purchase
        safe_command[:merchant] = purchase.fetch(:merchant)
        safe_command[:amount] = purchase.fetch(:amount)
        safe_command[:splits] = []
      end
      input = safe_command.merge(
        source_type: "manual_chat",
        raw_input: raw_input,
        category_context: [ raw_input, command[:resolved_message] ].compact.join(" ")
      )
      input[:budget_category_id] = input.delete(:category_id) if input[:category_id].present?
      result = Operations::Runner.new(household, user: user).run(
        operation_key: "transaction.draft.create",
        input: input,
        idempotency_key: idempotency_key,
        source: "mia"
      )
      Result.new(success: true, draft: result.subject.reload, errors: [])
    rescue ArgumentError => e
      Result.new(success: false, draft: nil, errors: [ e.message ])
    rescue ActiveRecord::RecordInvalid => e
      Result.new(success: false, draft: nil, errors: e.record.errors.full_messages)
    end

    private

    attr_reader :household, :command, :raw_input, :user, :idempotency_key
  end
end
