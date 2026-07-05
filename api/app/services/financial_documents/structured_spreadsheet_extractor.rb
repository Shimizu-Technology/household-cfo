# frozen_string_literal: true

module FinancialDocuments
  class StructuredSpreadsheetExtractor
    REQUIRED_HEADERS = %w[type label amount].freeze
    TRANSACTION_REQUIRED_HEADERS = %w[date amount].freeze
    HEADER_ALIASES = {
      "name" => "label",
      "description" => "label",
      "payee" => "merchant",
      "merchant name" => "merchant",
      "transaction date" => "date",
      "posted date" => "date",
      "occurred_on" => "date",
      "debit" => "amount",
      "withdrawal" => "amount",
      "value" => "amount",
      "balance" => "amount",
      "minimum_payment" => "payment",
      "minimum payment" => "payment",
      "debt_payment" => "payment",
      "debt payment" => "payment",
      "type/category" => "category",
      "category_name" => "category"
    }.freeze
    TYPE_ALIASES = {
      "income" => "income_source",
      "income source" => "income_source",
      "income_source" => "income_source",
      "expense" => "expense_item",
      "expense item" => "expense_item",
      "expense_item" => "expense_item",
      "asset" => "account",
      "account" => "account",
      "debt" => "debt",
      "goal" => "goal",
      "note" => "profile_note",
      "profile note" => "profile_note",
      "profile_note" => "profile_note"
    }.freeze

    Result = Data.define(:success, :data, :error) do
      def success?
        success == true
      end
    end

    def initialize(file_path:, filename:, document_kind: "spreadsheet")
      @file_path = file_path
      @filename = filename
      @document_kind = document_kind
    end

    def call
      summary = SpreadsheetSummarizer.new(file_path: file_path, filename: filename).call
      items = extract_items(summary)
      transaction_drafts = extract_transaction_drafts(summary)
      return failure("No structured Household CFO rows found") if items.empty? && transaction_drafts.empty?

      success(
        document_kind: document_kind == "statement" ? "statement" : "spreadsheet",
        document_date: nil,
        period_start_on: transaction_drafts.filter_map { |draft| draft[:occurred_on] }.min,
        period_end_on: transaction_drafts.filter_map { |draft| draft[:occurred_on] }.max,
        summary: structured_summary(items, transaction_drafts),
        confidence: "high",
        warnings: [],
        items: items,
        transaction_drafts: transaction_drafts
      )
    rescue StandardError => e
      failure(e.message)
    end

    private

    attr_reader :file_path, :filename, :document_kind

    def extract_items(summary)
      Array(summary[:sheets]).flat_map do |sheet|
        rows = Array(sheet[:rows])
        header_row = rows.find { |row| structured_header?(row[:values]) }
        next [] unless header_row

        header_map = header_map_for(header_row[:values])
        rows.drop_while { |row| row[:row] <= header_row[:row] }.filter_map do |row|
          item_from_row(row[:values], header_map)
        end
      end.first(Extractor::MAX_ITEMS)
    end

    def structured_header?(values)
      normalized = Array(values).map { |value| header_key(value) }
      REQUIRED_HEADERS.all? { |header| normalized.include?(header) }
    end

    def transaction_header?(values)
      normalized = Array(values).map { |value| header_key(value) }
      TRANSACTION_REQUIRED_HEADERS.all? { |header| normalized.include?(header) } && (normalized.include?("merchant") || normalized.include?("label"))
    end

    def header_map_for(values)
      Array(values).each_with_index.each_with_object({}) do |(value, index), map|
        key = header_key(value)
        map[key] = index if key.present?
      end
    end

    def header_key(value)
      raw = value.to_s.unicode_normalize(:nfkc).strip.downcase
      normalized = raw.gsub(/[\r\n]+/, " ").squish
      aliased = HEADER_ALIASES.fetch(normalized, normalized)
      aliased.gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, "")
    end

    def extract_transaction_drafts(summary)
      Array(summary[:sheets]).flat_map do |sheet|
        rows = Array(sheet[:rows])
        header_row = rows.find { |row| transaction_header?(row[:values]) }
        next [] unless header_row

        header_map = header_map_for(header_row[:values])
        rows.drop_while { |row| row[:row] <= header_row[:row] }.filter_map do |row|
          transaction_draft_from_row(row[:values], header_map, row_number: row[:row])
        end
      end.first(HouseholdFinance::DocumentTransactionDraftPersister::MAX_DRAFTS)
    end

    def transaction_draft_from_row(values, header_map, row_number:)
      occurred_on = parsed_date(cell(values, header_map, "date"))
      merchant = clean_text(cell(values, header_map, "merchant") || cell(values, header_map, "label"), max_length: 120)
      amount_cents = money_cents(cell(values, header_map, "amount"), negative_as_magnitude: true)
      category = clean_text(cell(values, header_map, "category"), max_length: 120)
      notes = clean_text(cell(values, header_map, "notes"), max_length: 500)
      return if occurred_on.blank? || merchant.blank? || amount_cents.blank? || amount_cents <= 0

      {
        occurred_on: occurred_on,
        merchant: merchant,
        total_amount: HouseholdFinance::Money.dollars(amount_cents),
        total_amount_cents: amount_cents,
        source_type: document_kind == "statement" ? "statement" : "import",
        category_name: category,
        stack_key: expense_stack_key(normalized_token(category), category.presence || merchant),
        confidence: "high",
        evidence: notes.presence || "Spreadsheet row #{row_number}",
        raw_description: [ merchant, notes ].compact_blank.join(" — "),
        external_id: "row-#{row_number}",
        warnings: [],
        splits: [
          {
            category_name: category,
            stack_key: expense_stack_key(normalized_token(category), category.presence || merchant),
            amount: HouseholdFinance::Money.dollars(amount_cents),
            amount_cents: amount_cents,
            notes: notes,
            confidence: "high",
            row_number: row_number
          }
        ]
      }
    end

    def item_from_row(values, header_map)
      type = target_type(cell(values, header_map, "type"))
      return unless type

      label = clean_text(cell(values, header_map, "label"), max_length: 120)
      return if label.blank? && type != "profile_note"

      amount_cents = money_cents(cell(values, header_map, "amount"), negative_as_magnitude: accounting_negative_as_magnitude?(type))
      category = normalized_token(cell(values, header_map, "category"))
      cadence = normalized_cadence(cell(values, header_map, "cadence"))
      notes = clean_text(cell(values, header_map, "notes"), max_length: 1000)
      payment_cents = payment_cents_for(cell(values, header_map, "payment"), notes)

      build_item(type, label, amount_cents, category, cadence, notes, payment_cents)
    end

    def build_item(type, label, amount_cents, category, cadence, notes, payment_cents)
      case type
      when "income_source"
        return if amount_cents.blank?

        base_item(type, label, amount_cents, cadence, notes).merge(source_type: income_source_type(category, label))
      when "expense_item"
        return if amount_cents.blank?

        base_item(type, label, amount_cents, cadence, notes).merge(stack_key: expense_stack_key(category, label))
      when "account"
        return if amount_cents.blank?

        base_item(type, label, nil, cadence, notes).merge(balance_cents: amount_cents, account_type: account_type(category, label))
      when "debt"
        return if amount_cents.blank? && payment_cents.blank?

        base_item(type, label, nil, cadence, notes).merge(balance_cents: amount_cents, payment_cents: payment_cents, debt_type: debt_type(category, label))
      when "goal"
        return if amount_cents.blank?

        base_item(type, label, amount_cents, cadence, notes).merge(metadata: { "goal_type" => goal_type(category) }.compact)
      when "profile_note"
        base_item(type, label.presence || "Document note", nil, cadence, notes)
      end
    end

    def base_item(type, label, amount_cents, cadence, notes)
      {
        target_type: type,
        label: label.presence || type.tr("_", " ").titleize,
        amount_cents: amount_cents,
        balance_cents: nil,
        payment_cents: nil,
        cadence: cadence,
        source_type: nil,
        stack_key: nil,
        account_type: nil,
        debt_type: nil,
        confidence: "high",
        evidence: notes.presence || label,
        metadata: {}
      }
    end

    def cell(values, header_map, key)
      index = header_map[key]
      return nil if index.nil?

      values[index]
    end

    def target_type(value)
      TYPE_ALIASES[normalized_type(value)]
    end

    def normalized_type(value)
      value.to_s.unicode_normalize(:nfkc).strip.downcase.tr("_", " ").squish
    end

    def normalized_token(value)
      value.to_s.unicode_normalize(:nfkc).downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, "")
    end

    def normalized_cadence(value)
      token = normalized_token(value)
      token = "one_time" if token.in?(%w[one once oneoff one_off current balance])
      token.in?(IncomeSource::CADENCES) ? token : "monthly"
    end

    def income_source_type(category, label)
      return category if category.in?(IncomeSource::SOURCE_TYPES)

      label_token = normalized_token(label)
      return "job" if label_token.match?(/salary|paycheck|wage|primary/)
      return "business" if label_token.match?(/business|consult|side|self/)
      return "rental" if label_token.match?(/rent/)
      return "bonus" if label_token.match?(/bonus/)

      "other"
    end

    def expense_stack_key(category, label)
      return category if category.in?(ExpenseItem::STACK_KEYS)

      case category
      when "fixed", "fixed_expenses", "fixed_essentials", "must_pay", "must_pay_bills", "essential", "essentials"
        "non_discretionary"
      when "expected", "expected_sinking", "expected_sinking_fund", "planned_irregular", "known_irregular"
        "sinking_expected"
      when "unexpected", "unexpected_sinking", "unexpected_sinking_fund", "life_happens", "buffer"
        "sinking_unexpected"
      when "flexible", "flexible_spend", "wants", "choice", "choices"
        "discretionary"
      else
        inferred_expense_stack_key(label)
      end
    end

    def inferred_expense_stack_key(label)
      token = normalized_token(label)
      return "non_discretionary" if token.match?(/rent|mortgage|utility|utilities|power|water|internet|phone|insurance|childcare|tuition|loan_minimum|minimum_payment/)
      return "sinking_expected" if token.match?(/maintenance|registration|holiday|travel|back_to_school|annual|planned|expected/)
      return "sinking_unexpected" if token.match?(/medical|family|repair|emergency|unexpected|buffer/)

      "discretionary"
    end

    def account_type(category, label)
      return category if category.in?(Account::ACCOUNT_TYPES)

      token = normalized_token(label)
      return "emergency_fund" if token.match?(/emergency|runway/)
      return "retirement" if token.match?(/retirement|401k|ira/)
      return "investment" if token.match?(/investment|brokerage/)
      return "checking" if token.match?(/checking/)
      return "savings" if token.match?(/saving/)
      return "property" if token.match?(/home|house|property/)

      "other"
    end

    def debt_type(category, label)
      return category if category.in?(Debt::DEBT_TYPES)

      token = normalized_token(label)
      return "credit_card" if token.match?(/visa|mastercard|amex|discover|card|credit/)
      return "student_loan" if token.match?(/student/)
      return "auto_loan" if token.match?(/auto|car/)
      return "mortgage" if token.match?(/mortgage/)
      return "medical" if token.match?(/medical/)
      return "personal_loan" if token.match?(/personal/)

      "other"
    end

    def goal_type(category)
      category if category.in?(Goal::GOAL_TYPES)
    end

    def accounting_negative_as_magnitude?(type)
      type.in?(%w[expense_item debt])
    end

    def structured_summary(items, transaction_drafts)
      parts = []
      parts << "#{items.length} budget value#{'s' unless items.length == 1}" if items.any?
      parts << "#{transaction_drafts.length} transaction draft#{'s' unless transaction_drafts.length == 1}" if transaction_drafts.any?
      "Mia found #{parts.to_sentence} for review."
    end

    def payment_cents_for(value, notes)
      direct = money_cents(value, negative_as_magnitude: true)
      return direct if direct.present?

      match = notes.to_s.match(/(?:minimum\s+payment|min\s+payment|payment)\D{0,20}(\(?\$?\d[\d,]*(?:\.\d{1,2})?\)?)/i)
      money_cents(match[1], negative_as_magnitude: true) if match
    end

    def parsed_date(value)
      return value.to_date if value.respond_to?(:to_date) && !value.is_a?(String)
      return if value.blank?

      text = value.to_s.squish
      parse_date_with_formats(text)
    end

    def parse_date_with_formats(text)
      Date.iso8601(text)
    rescue ArgumentError
      %w[%m/%d/%Y %m-%d-%Y %Y/%m/%d %B\ %d,\ %Y %b\ %d,\ %Y].each do |format|
        parsed = parse_date_with_format(text, format)
        return parsed if parsed
      end
      nil
    end

    def parse_date_with_format(text, format)
      Date.strptime(text, format)
    rescue ArgumentError
      nil
    end

    def money_cents(value, negative_as_magnitude: false)
      text = value.to_s.unicode_normalize(:nfkc).strip
      return nil if text.blank?

      decimal = parsed_money_decimal(text)
      if decimal.negative?
        return nil unless negative_as_magnitude

        decimal = decimal.abs
      end

      (decimal * 100).round.to_i
    rescue ArgumentError, FloatDomainError
      nil
    end

    def parsed_money_decimal(text)
      accounting_negative = text.match?(/\A\(\s*\$?\s*\d[\d,\s]*(?:\.\d{1,2})?\s*\)\z/)
      normalized = text.gsub(/[$,\s]/, "")
      normalized = "-#{normalized.delete_prefix("(").delete_suffix(")")}" if accounting_negative
      BigDecimal(normalized)
    end

    def clean_text(value, max_length:)
      value.to_s.unicode_normalize(:nfkc).gsub(/[[:cntrl:]]/, " ").gsub(/[<>`]/, "").squish.truncate(max_length, omission: "…")
    end

    def success(data)
      Result.new(success: true, data: data, error: nil)
    end

    def failure(error)
      Result.new(success: false, data: nil, error: error)
    end
  end
end
