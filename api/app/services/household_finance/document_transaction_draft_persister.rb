module HouseholdFinance
  class DocumentTransactionDraftPersister
    MAX_DRAFTS = 500
    MAX_SPLITS = 12
    CONFIDENCE_LEVEL_DECIMALS = {
      "high" => BigDecimal("0.90"),
      "medium" => BigDecimal("0.65"),
      "low" => BigDecimal("0.35")
    }.freeze

    # summary: the reader's summary of the whole document. A one-purchase
    # receipt's summary can say how it was paid when the row itself doesn't.
    def initialize(document_import, transaction_drafts, summary: nil)
      @document_import = document_import
      @summary = summary
      @household = document_import.household
      @transaction_drafts = Array(transaction_drafts)
      limit = @transaction_drafts.all? { |draft| draft.is_a?(Hash) && draft[:financial_source_event_id].present? } ? FinancialDocuments::AccountingContract::MAX_EVENTS : MAX_DRAFTS
      if @transaction_drafts.length > limit
        raise ArgumentError, "Document contains more than #{limit} transaction rows; split it into smaller date ranges before staging reviews."
      end
      @category_suggester = TransactionCategorySuggester.new(household)
      @created_count = 0
      @match_count = 0
      @warnings = []
    end

    attr_reader :created_count, :match_count, :warnings

    def call
      FinancialPicture.set(household_id: household.id, generation: document_import.financial_generation) { perform }
    end

    def perform
      FinancialGenerationGuard.source!(document_import)
      source_ids = transaction_drafts.filter_map { |payload| payload.is_a?(Hash) && payload.deep_symbolize_keys[:financial_source_event_id] }
      @source_events = FinancialSourceEvent.joins(:financial_extraction_revision).where(id: source_ids, household_id: household.id,
        financial_extraction_revisions: { financial_document_import_id: document_import.id }).includes(:financial_extraction_revision).index_by(&:id)
      remove_pending_import_drafts!
      transaction_drafts.each_with_index do |payload, index|
        persist_payload(payload, index: index)
      end
      { created_count: created_count, match_count: match_count, warnings: warnings }
    end

    private

    attr_reader :document_import, :household, :transaction_drafts, :category_suggester

    def remove_pending_import_drafts!
      document_import.transaction_drafts.pending.find_each do |draft|
        # Keep source lineage and review history on re-extraction. Legacy
        # unlinked pending drafts retain their existing replacement behavior.
        draft.financial_source_event_id ? draft.update!(status: "ignored") : draft.destroy!
      end
    end

    def persist_payload(payload, index:)
      draft_payload = payload.is_a?(Hash) ? payload.deep_symbolize_keys : {}
      source_id = draft_payload[:financial_source_event_id]
      source_event = source_id.present? && @source_events[Integer(source_id, exception: false)]
      if source_id.present? && (!source_event || !source_event.expense_projection_eligible?)
        raise ArgumentError, "Source event is not an eligible expense from this household import."
      end
      occurred_on = parsed_date(draft_payload[:occurred_on])
      occurred_on ||= document_import.document_date || document_import.period_end_on unless source_event
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
      cash_cents = receipt_cash_cents(draft_payload, source_type, total_amount_cents)
      receipt_payment, total_amount_cents, splits = receipt_payment_for(draft_payload, source_type, total_amount_cents, splits)

      match_count_for_draft = persist_draft_transaction!(
        draft_payload: draft_payload,
        occurred_on: occurred_on,
        merchant: merchant,
        total_amount_cents: total_amount_cents,
        source_type: source_type,
        splits: splits,
        index: index,
        receipt_payment: receipt_payment,
        cash_payment: (CashPayment.receipt_payload(cash_cents) if cash_cents)
      )
      @created_count += 1
      @match_count += match_count_for_draft
    rescue ActiveRecord::RecordInvalid => e
      warnings << "Skipped transaction row #{index + 1}: #{e.record.errors.full_messages.to_sentence}."
    rescue ArgumentError => e
      # The saver's own refusals are written to be read.
      warnings << "Skipped transaction row #{index + 1}: #{e.message}."
    rescue StandardError => e
      # These warnings can reach the participant as the reason a file was not saved for review:
      # an unexpected error's own text (a database or driver message) stays in the log.
      Rails.logger.warn("[DocumentTransactionDraftPersister] row #{index + 1} not saved: #{e.class}: #{e.message}")
      warnings << "Skipped transaction row #{index + 1}: it could not be saved."
    end

    def persist_draft_transaction!(draft_payload:, occurred_on:, merchant:, total_amount_cents:, source_type:, splits:, index:, receipt_payment: nil, cash_payment: nil)
      matcher_results = []
      ApplicationRecord.transaction(requires_new: true) do
        draft = document_import.transaction_drafts.create!(
          household: household,
          financial_source_event: @source_events[Integer(draft_payload[:financial_source_event_id], exception: false)],
          occurred_on: occurred_on,
          merchant: merchant,
          total_amount_cents: total_amount_cents,
          budget_category: splits.first&.fetch(:budget_category),
          source_type: source_type,
          status: "pending",
          confidence: normalized_decimal(draft_payload[:confidence]),
          raw_input: raw_input_for(draft_payload, merchant),
          draft_payload: sanitized_draft_payload(draft_payload, index: index).merge({ ReceiptTenders::PAYLOAD_KEY => receipt_payment, CashPayment::PAYLOAD_KEY => cash_payment }.compact)
        )
        splits.each { |split| create_split!(draft, split) }
        matcher_results = TransactionDraftMatcher.new(draft).call
      end
      matcher_results.length
    end

    def normalized_splits(draft_payload, merchant:, total_amount_cents:)
      raw_splits = Array(draft_payload[:splits]).first(MAX_SPLITS)
      raw_splits = [ { amount: Money.dollars(total_amount_cents), category_name: draft_payload[:category_name], stack_key: draft_payload[:stack_key], notes: draft_payload[:evidence] } ] if raw_splits.empty?

      multiple_splits = raw_splits.length > 1
      raw_splits.filter_map do |raw_split|
        split = raw_split.is_a?(Hash) ? raw_split.deep_symbolize_keys : {}
        amount_cents = Money.cents(split[:amount].to_s)
        amount_cents = split[:amount_cents].to_i if amount_cents <= 0 && split[:amount_cents].present?
        next unless amount_cents.positive?

        category_name = sanitized_text(split[:category_name] || split[:label], max_length: 120)
        stack_key = normalized_stack_key(split[:stack_key])
        confidence = normalized_decimal(split[:confidence])
        suggestion = category_suggester.suggest(
          merchant: merchant,
          category_name: category_name,
          stack_key: stack_key,
          text: [ split[:notes], split[:line_label] ].compact.join(" "),
          confidence: confidence,
          merchant_fallback: !multiple_splits
        )
        category = suggestion.category
        {
          amount_cents: amount_cents,
          budget_category: category,
          category_name: category_name.presence || category&.name,
          stack_key: stack_key || category&.stack_key,
          notes: sanitized_text(split[:notes] || draft_payload[:evidence], max_length: 500),
          confidence: confidence,
          metadata: split.slice(:line_label, :row_number, :sku, :source_label).compact.merge(
            category_match_status: suggestion.match_status,
            category_match_reason: suggestion.match_reason,
            extracted_category_name: category_name.presence
          ).compact
        }
      end
    end

    # Part of a receipt paid with a gift card, voucher, store credit or rewards
    # is not new money (decision 4), so propose only the new money and scale
    # the splits to it. The receipt total and each split's receipt amount stay
    # on the draft so she can count all of it instead. Nothing counts until she
    # confirms. When the payment lines don't add up, the draft stays as read.
    def receipt_payment_for(draft_payload, source_type, total_amount_cents, splits)
      unchanged = [ nil, total_amount_cents, splits ]
      return unchanged unless source_type == "receipt" && draft_payload[:financial_source_event_id].blank?

      texts = [ draft_payload[:evidence], *Array(draft_payload[:warnings]) ]
      texts << @summary if transaction_drafts.length == 1
      reading = ReceiptTenders.read(total_cents: total_amount_cents, texts: texts)
      return unchanged unless reading

      payment = { "reader" => "receipt_tenders_v1", "receipt_total_cents" => reading.receipt_total_cents,
        "new_money_cents" => reading.new_money_cents, "paid_with" => reading.paid_with }
      with_receipt_amounts = splits.map { |split| split.merge(metadata: split[:metadata].merge(receipt_amount_cents: split[:amount_cents])) }
      # All of it paid without new money: a purchase can't be $0, so she sees
      # why and chooses Not now herself.
      return [ payment, total_amount_cents, with_receipt_amounts ] if reading.new_money_cents.zero?

      shares = RefundCredits.proportional(splits.each_with_index.map { |split, index| { category_id: index, amount_cents: split[:amount_cents] } }, reading.new_money_cents)
      # A split too small to keep a whole cent: leave the draft as read.
      return unchanged unless shares.length == splits.length

      scaled = with_receipt_amounts.zip(shares).map do |split, share|
        split.merge(amount_cents: share[:amount_cents], metadata: split[:metadata].merge(new_money_amount_cents: share[:amount_cents]))
      end
      [ payment, reading.new_money_cents, scaled ]
    end

    # A receipt paid wholly or partly in cash names cash she took out (decision 3); the card asks which withdrawal.
    def receipt_cash_cents(draft_payload, source_type, total_amount_cents)
      return unless source_type == "receipt" && draft_payload[:financial_source_event_id].blank?

      texts = [ draft_payload[:evidence], *Array(draft_payload[:warnings]) ]
      texts << @summary if transaction_drafts.length == 1
      ReceiptTenders.cash_cents(total_cents: total_amount_cents, texts: texts)
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
        financial_source_event_id: draft_payload[:financial_source_event_id],
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

      confidence_level = value.to_s.downcase
      return CONFIDENCE_LEVEL_DECIMALS.fetch(confidence_level) if CONFIDENCE_LEVEL_DECIMALS.key?(confidence_level)

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
