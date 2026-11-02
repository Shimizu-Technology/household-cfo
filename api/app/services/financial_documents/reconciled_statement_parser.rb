# frozen_string_literal: true

module FinancialDocuments
  # A table reader qualified by source evidence, not the bank's name or fixed
  # coordinates. Acceptance requires a complete date/amount census, printed row
  # count, both movement totals and opening/closing arithmetic. Nothing inferred
  # from a running balance can fill a missing amount.
  class ReconciledStatementParser
    VERSION = "reconciled_statement_v1"
    DATE = /\A\d{1,2}\/\d{1,2}(?:\/\d{4})?\z/
    MONEY = /\A([+-]?)(?:\$)?((?:\d{1,3}(?:,\d{3})+|\d+))\.(\d{2})\z/
    Invalid = Class.new(StandardError)
    RowError = Class.new(Invalid)
    Result = NativeStatementParser::Result
    attr_reader :failed_pages, :recognized

    def initialize(pages:)
      @pages = pages
      @rows = []
      @failed_pages = []
      @page_dates = {}
    end

    def call
      read_header!
      @recognized = true
      @pages.each do |page|
        yield(page[:number], @pages.length) if block_given?
        @page_dates[page[:number]] = page[:runs].select { |run| run[:text].match?(DATE) }.sort_by { |run| -run[:y] }.map { |run| date(run[:text]) }
        @rows.concat(read_page(page))
      rescue RowError
        @failed_pages << page[:number]
      end
      return rejected("table_pages_need_review") if failed_pages.any?

      finish
    rescue Invalid, ArgumentError
      rejected("statement_evidence_incomplete")
    end

    # Only failed pages may be supplied by the model. Recheck the original
    # physical row census and ALL statement arithmetic before publishing a result.
    def recover(page_accounting)
      raise Invalid unless page_accounting.keys.sort == failed_pages.sort
      page_accounting.each do |page, accounting|
        events = accounting.fetch(:events)
        raise Invalid unless accounting[:contract_version] == AccountingContract::VERSION
        raise Invalid unless events.length == @page_dates.fetch(page).length
        raise Invalid unless events.map { |event| event[:posted_on] } == @page_dates.fetch(page)
        raise Invalid unless events.all? { |event| event.dig(:locator, :page) == page && event[:row_kind].in?(%w[posted informational]) }
        events.each_with_index do |event, index|
          amount = event[:signed_amount_cents] || event.dig(:evidence, :displayed_amount_cents)
          raise Invalid unless amount.is_a?(Integer)
          @rows << { account_key: @account[:account_key], row_kind: event[:row_kind], event_type: event[:event_type],
            signed_amount_cents: amount, amount_column_cents: amount, posted_on: event[:posted_on],
            locator: { page: page, row: index + 1 }, merchant: event.dig(:evidence, :merchant),
            raw_description: event.dig(:evidence, :raw_description), evidence: event.dig(:evidence, :evidence) }
        end
      end
      @rows.sort_by! { |row| row[:locator].values_at(:page, :row) }
      finish(recovered: true)
    rescue Invalid, KeyError, ArgumentError
      rejected("recovered_statement_does_not_reconcile")
    end

    private

    def read_header!
      raise Invalid unless @pages.any? && @pages.length <= NativeStatementParser::MAX_PAGES
      raise Invalid if @pages.sum { |page| page[:runs].length } > NativeStatementParser::MAX_RUNS
      @lines = @pages.flat_map { |page| lines(page) }.map { |line| line.pluck(:text).join(" ") }
      text = @lines.join("\n")
      period = text.scan(/Statement (?:period|cycle):\s*(\d{4}-\d{2}-\d{2})\s*(?:through|to|–|-)\s*(\d{4}-\d{2}-\d{2})/i).uniq
      raise Invalid unless period.one?
      @start, @finish = period.sole.map { |value| Date.iso8601(value) }
      raise Invalid unless (@finish - @start).between?(0, 366)
      basis = if text.match?(/Beginning \+ credits - debits = ending|\b(?:checking|savings) account\b/i)
        "asset"
      elsif text.match?(/Prior balance \+ charges - payments\/refunds = new balance|\bcredit card statement\b/i)
        "liability"
      end
      raise Invalid unless basis
      identifiers = text.scan(/Account:\s*([^|\n]+)/i).flatten.map(&:strip).uniq
      raise Invalid unless identifiers.one?
      identifier = identifiers.sole.gsub(/\D/, "").last(4)
      raise Invalid unless identifier.length == 4
      @posted_count = one_value(/Posted rows:\s*(\d+)/i).to_i
      @account = { account_key: "statement:#{identifier}", masked_identifier: "****#{identifier}", label: "Statement account ****#{identifier}",
        account_basis: basis, period_start_on: @start, period_end_on: @finish,
        opening_balance_cents: header_money("Beginning balance"), closing_balance_cents: header_money("Ending balance"),
        printed_credit_cents: header_money("Posted credits"), printed_debit_cents: header_money("Posted debits"),
        header_evidence: "Printed statement period, account, balances, movement totals and row count" }
      @signed_card = text.match?(/Purchases positive; payments and refunds negative/i)
    end

    def one_value(pattern)
      values = @lines.flat_map { |line| line.scan(pattern).flatten }.uniq
      raise Invalid unless values.one?
      values.sole
    end

    def header_money(label)
      value = money(one_value(/#{Regexp.escape(label)}:\s*([+$\d,.-]+)/i))
      raise Invalid if label.start_with?("Posted") && value.negative?
      value
    end

    def read_page(page)
      rows = []
      header = nil
      in_table = false
      consumed_dates = []
      lines(page).each do |line|
        texts = line.pluck(:text)
        if texts.include?("Date") && texts.any? { |text| text.match?(/\A(?:Description|Payee|Details)\z/i) }
          raise RowError if in_table
          header = columns(line)
          in_table = true
          next
        end
        if texts.first.to_s.match?(/\A(?:Posted totals|Continued on next page)\b/i)
          in_table = false
          next
        end
        date_run = line.find { |run| run[:text].match?(DATE) }
        unless date_run
          # Never ignore a money-bearing or text-only continuation inside the
          # table. Wrapped/ambiguous rows are confined to this page's fallback.
          raise RowError if in_table && line.any? { |run| run[:text].match?(/\d[\d,]*\.\d|\A\p{L}/) }
          next
        end
        raise RowError unless in_table && header && (date_run[:x] - header[:date][:x]).abs < 3
        raise RowError unless line.count { |run| run[:text].match?(DATE) } == 1
        consumed_dates << date(date_run[:text])
        rows << read_row(line, header, date_run, page[:number], rows.length + 1)
      end
      raise RowError unless consumed_dates == @page_dates.fetch(page[:number])
      raise RowError if header.nil? # A scan or unknown page is never assumed blank.
      rows
    end

    def columns(line)
      header = {}
      line.each do |run|
        key = case run[:text].downcase
        when "date" then :date
        when "description", "payee", "details" then :description
        when "debit", "withdrawal", "charges" then :debit
        when "credit", "deposit", "payments" then :credit
        when "amount" then :amount
        when "balance" then :balance
        end
        raise RowError unless key && !header.key?(key)
        header[key] = run
      end
      raise RowError unless header[:date] && header[:description]
      raise RowError unless (header[:debit] && header[:credit] && !header[:amount]) || (@signed_card && @account[:account_basis] == "liability" && header[:amount] && !header[:debit] && !header[:credit])
      header
    end

    def read_row(line, header, date_run, page, row)
      fields = header.sort_by { |_key, run| run[:x] }
      values = Hash.new { |hash, key| hash[key] = [] }
      line.reject { |run| run == date_run }.each do |run|
        key = fields.reverse.find { |_name, label| run[:x] >= label[:x] - 32 }&.first
        raise RowError unless key && key != :date
        values[key] << run[:text]
      end
      body = values.delete(:description).join(" ").presence || raise(RowError)
      amounts = values.transform_values { |texts| raise RowError unless texts.one?; money(texts.sole) }
      if header[:amount]
        printed = amounts.fetch(:amount) { raise RowError }
        signed = -printed
      else
        raise RowError unless amounts.key?(:debit) ^ amounts.key?(:credit)
        raise RowError if amounts.values.any?(&:negative?)
        signed = amounts.key?(:debit) ? -amounts[:debit] : amounts[:credit]
      end
      pending = body.match?(/\[PENDING\]/i)
      type = event_type(body, signed)
      { account_key: @account[:account_key], row_kind: pending ? "informational" : "posted", event_type: type,
        signed_amount_cents: signed, amount_column_cents: signed, posted_on: date(date_run[:text]),
        locator: { page: page, row: row }, merchant: MerchantNormalizer.call(body), raw_description: mask(body), evidence: mask(body),
        running_balance_cents: amounts[:balance] }
    rescue Invalid, KeyError
      raise RowError
    end

    def finish(recovered: false)
      posted = @rows.reject { |row| row[:row_kind] == "informational" }
      raise Invalid unless posted.length == @posted_count && @rows.length <= AccountingContract::MAX_EVENTS
      raise Invalid unless @rows.pluck(:posted_on).each_cons(2).all? { |left, right| left <= right }
      credits = posted.sum { |row| [ row[:signed_amount_cents], 0 ].max }
      debits = posted.sum { |row| [ -row[:signed_amount_cents], 0 ].max }
      factor = @account[:account_basis] == "asset" ? 1 : -1
      balance = @account[:opening_balance_cents]
      @rows.each do |row|
        balance += row[:signed_amount_cents] * factor unless row[:row_kind] == "informational"
        raise Invalid if row[:running_balance_cents] && row[:running_balance_cents] != balance
      end
      raise Invalid unless credits == @account[:printed_credit_cents] && debits == @account[:printed_debit_cents] && balance == @account[:closing_balance_cents]
      @account[:printed_row_count] = @rows.length
      accounting = AccountingContract.normalize({ contract_version: AccountingContract::VERSION, accounts: [ @account ], events: @rows },
        coverage: { expected_page_count: @pages.length, processed_pages: (1..@pages.length).to_a, reported_row_count: @rows.length })
      raise Invalid if accounting[:events].any? { |event| event[:row_kind] == "unresolved" }
      Result.new(success: true, error: nil,
        data: { document_kind: "statement", document_date: @finish, period_start_on: @start, period_end_on: @finish,
          summary: "Read #{@rows.length} rows from every statement page. Review the purchases before approval.", confidence: "high",
          warnings: [ "Printed row counts, totals and balances agree. Account identity and classifications still need your review." ],
          items: [], transaction_drafts: [], source_accounting: accounting },
        metadata: { extraction_mode: recovered ? "reconciled_statement_hybrid" : "native_statement", parser_version: VERSION, template: VERSION,
          page_count: @pages.length, financial_row_count: posted.length, informational_row_count: @rows.length - posted.length, printed_arithmetic_verified: true })
    rescue Invalid
      rejected("statement_does_not_reconcile")
    end

    def event_type(body, signed)
      return "debt_payment" if body.match?(/(?:card|visa|loan)\s+payment|payment\s+(?:received|thank you)/i)
      return "transfer" if body.match?(/\btransfer\b/i)
      return "cash_withdrawal" if body.match?(/\bATM\b|cash withdrawal/i)
      return "refund" if signed.positive? && body.match?(/refund|return|reversal/i)
      return "income" if signed.positive? && body.match?(/payroll|salary|direct deposit|ACH CREDIT/i)
      return "interest" if body.match?(/\binterest\b/i)
      return "fee" if signed.negative? && body.match?(/\bfee\b/i)
      return "purchase" if signed.negative?
      "unknown"
    end

    def lines(page)
      page[:runs].sort_by { |run| [ -run[:y], run[:x] ] }.slice_when { |left, right| (left[:y] - right[:y]).abs > 1 }.to_a.map { |line| line.sort_by { |run| run[:x] } }
    end

    def date(text)
      parts = text.split("/").map(&:to_i)
      candidates = parts.length == 3 ? [ Date.new(parts[2], parts[0], parts[1]) ] : (@start.year..@finish.year).map { |year| Date.new(year, parts[0], parts[1]) rescue nil }.compact
      candidates.select! { |value| value.between?(@start, @finish) }
      raise Invalid unless candidates.one?
      candidates.sole
    end

    def money(text)
      match = text.match(MONEY) || raise(Invalid)
      cents = match[2].delete(",").to_i * 100 + match[3].to_i
      raise Invalid if cents > AccountingContract::CENT_LIMIT
      match[1] == "-" ? -cents : cents
    end

    def mask(text) = text.gsub(/\d{8,}/) { |value| "****#{value.last(4)}" }
    def rejected(reason) = Result.new(success: false, data: nil, error: reason, metadata: { reason: reason, parser_version: VERSION })
  end
end
