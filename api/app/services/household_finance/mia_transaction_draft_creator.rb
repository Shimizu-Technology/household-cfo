module HouseholdFinance
  class MiaTransactionDraftCreator
    Result = Data.define(:success, :draft, :errors) do
      def success?
        success == true
      end
    end

    def initialize(household, command:, raw_input:)
      @household = household
      @command = command.to_h.deep_symbolize_keys
      @raw_input = raw_input.to_s.squish
    end

    def call
      occurred_on = parsed_date(command[:occurred_on])
      merchant = bounded_text(command[:merchant], 120)
      raise ArgumentError, "Transaction merchant is required" if merchant.blank?

      amount_cents = parsed_amount_cents(command[:amount])
      splits = normalized_splits(merchant, amount_cents)
      raise ArgumentError, "Transaction splits must equal transaction total" unless splits.sum { |split| split.fetch(:amount_cents) } == amount_cents

      draft = nil
      ApplicationRecord.transaction do
        draft = household.transaction_drafts.create!(
          occurred_on: occurred_on,
          merchant: merchant,
          total_amount_cents: amount_cents,
          budget_category: splits.first&.fetch(:budget_category),
          source_type: "manual_chat",
          status: "pending",
          confidence: BigDecimal("0.90"),
          raw_input: raw_input,
          draft_payload: {
            parser: "mia_structured_transaction_v1",
            suggested_category_reason: suggested_category_reason(splits.first&.fetch(:budget_category))
          }
        )
        splits.each do |split|
          draft.transaction_draft_splits.create!(
            budget_category: split.fetch(:budget_category),
            amount_cents: split.fetch(:amount_cents),
            category_name: split[:category_name],
            stack_key: split[:stack_key],
            confidence: BigDecimal("0.90"),
            metadata: {}
          )
        end
        TransactionDraftMatcher.new(draft).call
      end

      Result.new(success: true, draft: draft.reload, errors: [])
    rescue ArgumentError => e
      Result.new(success: false, draft: nil, errors: [ e.message ])
    rescue ActiveRecord::RecordInvalid => e
      Result.new(success: false, draft: nil, errors: e.record.errors.full_messages)
    end

    private

    attr_reader :household, :command, :raw_input

    def normalized_splits(merchant, amount_cents)
      raw_splits = Array(command[:splits])
      return raw_splits.map { |split| normalized_split(split) } if raw_splits.any?

      category = selected_category(command[:category_id], command[:category_name]) || suggested_category(merchant)
      [
        {
          budget_category: category,
          amount_cents: amount_cents,
          category_name: category&.name || bounded_text(command[:category_name], 120).presence,
          stack_key: category&.stack_key
        }
      ]
    end

    def normalized_split(raw_split)
      split = raw_split.to_h.deep_symbolize_keys
      category = selected_category(split[:category_id], split[:category_name])
      raise ArgumentError, "Budget category not found" unless category

      {
        budget_category: category,
        amount_cents: parsed_amount_cents(split[:amount]),
        category_name: category.name,
        stack_key: category.stack_key
      }
    end

    def selected_category(id, name)
      return if id.to_i.zero? && name.to_s.squish.blank?

      category = if id.to_i.positive?
        household.budget_categories.find_by(id: id.to_i)
      else
        household.budget_categories.find_by("LOWER(name) = ?", name.to_s.squish.downcase)
      end
      raise ArgumentError, "Budget category not found" unless category
      raise ArgumentError, "Budget category is archived. Restore it or choose an active category before confirming." unless category.active?

      category
    end

    def suggested_category(merchant)
      TransactionCategorySuggester.new(household).call(
        merchant: merchant,
        category_name: command[:category_name],
        stack_key: command[:stack_key],
        text: [ raw_input, command[:resolved_message] ].compact.join(" ")
      )
    end

    def suggested_category_reason(category)
      category ? "Matched #{category.name} from active budget categories." : "No active category matched."
    end

    def parsed_date(value)
      date = Date.iso8601(value.to_s)
      raise ArgumentError, "Transaction date is outside supported budget years" unless AnnualBudgetManager.supported_year?(date.year)

      date
    rescue Date::Error
      raise ArgumentError, "Transaction date is invalid"
    end

    def parsed_amount_cents(value)
      cents = Money.cents!(value, message: "Transaction amount must be a number")
      raise ArgumentError, "Transaction amount must be greater than $0" unless cents.positive?

      cents
    end

    def bounded_text(value, max_length)
      value.to_s.unicode_normalize(:nfkc).gsub(/[[:cntrl:]]/, " ").gsub(/[<>`]/, "").squish.truncate(max_length, omission: "…")
    end
  end
end
