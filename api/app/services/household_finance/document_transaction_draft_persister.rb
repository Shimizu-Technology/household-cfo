module HouseholdFinance
  class DocumentTransactionDraftPersister
    MAX_DRAFTS = 120
    MAX_SPLITS = 12

    def initialize(document_import, transaction_drafts)
      @document_import = document_import
      @household = document_import.household
      @transaction_drafts = Array(transaction_drafts).first(MAX_DRAFTS)
      @category_suggester = TransactionCategorySuggester.new(household)
      @created_count = 0
      @match_count = 0
      @warnings = []
    end

    attr_reader :created_count, :match_count, :warnings

    def call
      remove_pending_import_drafts!
      transaction_drafts.each_with_index do |payload, index|
        persist_payload(payload, index: index)
      end
      { created_count: created_count, match_count: match_count, warnings: warnings }
    end

    private

    attr_reader :document_import, :household, :transaction_drafts, :category_suggester

    def remove_pending_import_drafts!
      document_import.transaction_drafts.pending.find_each(&:destroy!)
    end

    def persist_payload(payload, index:)
      draft_payload = payload.is_a?(Hash) ? payload.deep_symbolize_keys : {}
      occurred_on = parsed_date(draft_payload[:occurred_on]) || document_import.document_date || document_import.period_end_on
      unless occurred_on && AnnualBudgetManager.supported_year?(occurred_on.year)
        warnings << "Skipped transaction row #{index + 1}: transaction date is outside supported budget years."
        return
      end

      total_amount_cents = Money.cents(draft_payload[:total_amount].to_s)
      total_amount_cents = draft_payload[:total_amount_cents].to_i if total_amount_cents <= 0 && draft_payload[:total_amount_cents].present?
      unless total_amount_cents.positive?
        warnings << "Skipped transaction row #{index + 1}: transaction amount was missing or not positive."
        return
      end

      merchant = sanitized_text(draft_payload[:merchant], max_length: 120).presence || "Document transaction"
      source_type = normalized_source_type(draft_payload[:source_type])
      splits = normalized_splits(draft_payload, merchant: merchant, total_amount_cents: total_amount_cents)
      unless split_sum_valid?(splits, total_amount_cents)
        warnings << "Skipped #{merchant}: split amounts did not equal the transaction total."
        return
      end

      match_count_for_draft = persist_draft_transaction!(
        draft_payload: draft_payload,
        occurred_on: occurred_on,
        merchant: merchant,
        total_amount_cents: total_amount_cents,
        source_type: source_type,
        splits: splits,
        index: index
      )
      @created_count += 1
      @match_count += match_count_for_draft
    rescue ActiveRecord::RecordInvalid => e
      warnings << "Skipped transaction row #{index + 1}: #{e.record.errors.full_messages.to_sentence}."
    rescue StandardError => e
      warnings << "Skipped transaction row #{index + 1}: #{e.message}."
    end

    def persist_draft_transaction!(draft_payload:, occurred_on:, merchant:, total_amount_cents:, source_type:, splits:, index:)
      matcher_results = []
      ApplicationRecord.transaction(requires_new: true) do
        draft = document_import.transaction_drafts.create!(
          household: household,
          occurred_on: occurred_on,
          merchant: merchant,
          total_amount_cents: total_amount_cents,
          budget_category: splits.first&.fetch(:budget_category),
          source_type: source_type,
          status: "pending",
          confidence: normalized_decimal(draft_payload[:confidence]),
          raw_input: raw_input_for(draft_payload, merchant),
          draft_payload: sanitized_draft_payload(draft_payload, index: index)
        )
        splits.each { |split| create_split!(draft, split) }
        matcher_results = TransactionDraftMatcher.new(draft).call
      end
      matcher_results.length
    end

    def normalized_splits(draft_payload, merchant:, total_amount_cents:)
      raw_splits = Array(draft_payload[:splits]).first(MAX_SPLITS)
      raw_splits = [ { amount: Money.dollars(total_amount_cents), category_name: draft_payload[:category_name], stack_key: draft_payload[:stack_key], notes: draft_payload[:evidence] } ] if raw_splits.empty?

      raw_splits.filter_map do |raw_split|
        split = raw_split.is_a?(Hash) ? raw_split.deep_symbolize_keys : {}
        amount_cents = Money.cents(split[:amount].to_s)
        amount_cents = split[:amount_cents].to_i if amount_cents <= 0 && split[:amount_cents].present?
        next unless amount_cents.positive?

        category_name = sanitized_text(split[:category_name] || split[:label], max_length: 120)
        stack_key = normalized_stack_key(split[:stack_key])
        category = category_suggester.call(
          merchant: merchant,
          category_name: category_name,
          stack_key: stack_key,
          text: [ split[:notes], draft_payload[:evidence], draft_payload[:raw_description] ].compact.join(" ")
        )
        {
          amount_cents: amount_cents,
          budget_category: category,
          category_name: category_name.presence || category&.name,
          stack_key: stack_key || category&.stack_key,
          notes: sanitized_text(split[:notes] || draft_payload[:evidence], max_length: 500),
          confidence: normalized_decimal(split[:confidence]),
          metadata: split.slice(:line_label, :row_number, :sku, :source_label).compact
        }
      end
    end

    def split_sum_valid?(splits, total_amount_cents)
      return false if splits.empty?

      splits.sum { |split| split.fetch(:amount_cents) } == total_amount_cents
    end

    def create_split!(draft, split)
      draft.transaction_draft_splits.create!(
        budget_category: split.fetch(:budget_category),
        amount_cents: split.fetch(:amount_cents),
        category_name: split[:category_name],
        stack_key: split[:stack_key],
        notes: split[:notes],
        confidence: split[:confidence],
        metadata: split[:metadata] || {}
      )
    end

    def raw_input_for(draft_payload, merchant)
      sanitized_text(draft_payload[:raw_description] || draft_payload[:evidence], max_length: 1_000).presence ||
        "#{document_import.filename}: #{merchant}"
    end

    def sanitized_draft_payload(draft_payload, index:)
      {
        parser: "document_intelligence_v1",
        document_import_id: document_import.id,
        row_index: index,
        evidence: sanitized_text(draft_payload[:evidence], max_length: 500),
        external_id: sanitized_text(draft_payload[:external_id], max_length: 120),
        raw_description: sanitized_text(draft_payload[:raw_description], max_length: 500),
        warnings: Array(draft_payload[:warnings]).filter_map { |warning| sanitized_text(warning, max_length: 240).presence }.first(5)
      }.compact_blank
    end

    def normalized_source_type(source_type)
      value = source_type.to_s
      return value if value.in?(HouseholdTransaction::SOURCE_TYPES)

      case document_import.document_kind
      when "receipt" then "receipt"
      when "statement" then "statement"
      when "spreadsheet" then "import"
      else "screenshot"
      end
    end

    def normalized_stack_key(stack_key)
      value = stack_key.to_s
      value if value.in?(BudgetCategory::STACK_KEYS)
    end

    def normalized_decimal(value)
      return if value.blank?

      number = BigDecimal(value.to_s)
      return if number.negative?

      [ number, 1 ].min
    rescue ArgumentError
      nil
    end

    def parsed_date(value)
      return if value.blank?

      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def sanitized_text(value, max_length:)
      value.to_s.unicode_normalize(:nfkc).gsub(/[[:cntrl:]]/, " ").gsub(/[<>`]/, "").squish.truncate(max_length, omission: "…")
    end
  end
end
