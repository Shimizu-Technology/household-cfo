# frozen_string_literal: true

module FinancialDocuments
  # A table reader qualified by source evidence, not the bank's name or fixed
  # coordinates. Acceptance requires a complete date/amount census, printed row
  # count, both movement totals and opening/closing arithmetic. Nothing inferred
  # from a running balance can fill a missing amount.
  class ReconciledStatementParser
    VERSION = "reconciled_statement_v2"
    DATE = /\A\d{1,2}\/\d{1,2}(?:\/\d{4})?\z/
    PERIOD_DATE = /(?:\d{4}-\d{2}-\d{2}|\d{1,2}\/\d{1,2}\/\d{4})/
    MONEY = /\A([+-]?)(?:\$)?((?:\d{1,3}(?:,\d{3})+|\d+))\.(\d{2})\z/
    Invalid = Class.new(StandardError)
    RowError = Class.new(Invalid)
    Result = NativeStatementParser::Result
    attr_reader :failed_pages, :recognized, :page_types

    def initialize(pages:)
      @pages = pages.map do |page|
        # Keep the page in coverage, but do not interpret coordinates from a
        # rotated/cropped page. Other readable pages can still use native rows.
        readable = page[:rotation] == 0 && (page[:crop].nil? || page[:crop] == page[:box])
        page.merge(runs: readable ? page[:runs] : [])
      end
      @rows = []
      @failed_pages = []
      @page_dates = {}
      @page_rows = {}
      @page_types = {}
    end

    def call
      read_header!
      @recognized = true
      @pages.each do |page|
        yield(page[:number], @pages.length) if block_given?
        @page_types[page[:number]] = page_type(page)
        next if @page_types[page[:number]] == :non_transaction
        # Only a transaction table supplies a native date census. A scan with
        # a text footer (even a dated one) supplies no trustworthy row count.
        @page_dates[page[:number]] = @page_types[page[:number]] == :transaction ? page[:runs].select { |run| run[:text].match?(DATE) }.sort_by { |run| -run[:y] }.map { |run| date(run[:text]) } : nil
        @page_rows[page[:number]] = recovery_evidence(page)
        raise RowError if @page_types[page[:number]] == :unreadable
        @rows.concat(read_page(page))
      rescue RowError
        @failed_pages << page[:number]
      end
      return rejected("table_pages_need_review") if failed_pages.any?

      finish
    rescue Invalid, ArgumentError
      # Later pages were not read; earlier row failures cannot be repaired.
      @aborted = true
      @failed_pages = []
      rejected("statement_evidence_incomplete")
    end

    # Only failed pages may be supplied by the model. Recheck the original
    # physical row census and ALL statement arithmetic before publishing a result.
    def recover(page_accounting)
      raise Invalid if @aborted
      raise Invalid unless page_accounting.keys.sort == failed_pages.sort
      page_accounting.each do |page, accounting|
        raise Invalid unless accounting.is_a?(Hash)
        events = accounting.fetch(:events)
        raise Invalid unless accounting[:contract_version] == AccountingContract::VERSION
        dates = @page_dates.fetch(page)
        if dates
          raise Invalid unless events.length == dates.length && events.map { |event| event[:posted_on] } == dates
        else
          # Scanned/rotated pages have no trustworthy native census. Require
          # dated model rows, then reconcile the full printed posted count and
          # both totals against the preserved native pages below.
          raise Invalid if events.empty?
          raise Invalid unless events.all? { |event| event[:posted_on].is_a?(Date) && event[:posted_on].between?(@start, @finish) }
        end
        raise Invalid unless events.all? { |event| event.dig(:locator, :page) == page && event[:row_kind].in?(%w[posted informational]) }
        events.each_with_index do |event, index|
          amount = event[:signed_amount_cents] || event.dig(:evidence, :displayed_amount_cents)
          raise Invalid unless amount.is_a?(Integer)
          printed = @page_rows.fetch(page)[index]
          if printed
            raise Invalid if printed[:signed_amount_cents] && amount != printed[:signed_amount_cents]
            raise Invalid if printed[:row_kind] && event[:row_kind] != printed[:row_kind]
          end
          @rows << { account_key: @account[:account_key], row_kind: event[:row_kind], event_type: event[:event_type],
            signed_amount_cents: amount, amount_column_cents: amount, posted_on: event[:posted_on],
            locator: { page: page, row: index + 1 }, merchant: event.dig(:evidence, :merchant),
            raw_description: event.dig(:evidence, :raw_description), evidence: event.dig(:evidence, :evidence),
            running_balance_cents: printed&.dig(:running_balance_cents) }
        end
      end
      @rows.sort_by! { |row| row[:locator].values_at(:page, :row) }
      finish(recovered: true)
    rescue Invalid, KeyError, ArgumentError
      rejected("recovered_statement_does_not_reconcile")
    end

    private

    # Preserve any readable printed amounts/balances even when a wrapped row
    # makes this page need the model. A repair cannot override those facts.
    def recovery_evidence(page)
      header = nil
      lines(page).filter_map do |line|
        if table_header?(line)
          header = columns(line)
          next
        end
        next unless header
        run = line.find { |item| item[:text].match?(DATE) }
        next unless run
        [ run, line ]
      end.map.with_index do |(run, line), index|
        printed_row(line, header, run, page[:number], index + 1)
      rescue RowError
        nil
      end
    rescue RowError
      []
    end

    def read_header!
      raise Invalid unless @pages.any? && @pages.length <= NativeStatementParser::MAX_PAGES
      raise Invalid if @pages.sum { |page| page[:runs].length } > NativeStatementParser::MAX_RUNS
      @lines = @pages.flat_map { |page| lines(page) }.map { |line| line.pluck(:text).join(" ") }
      text = @lines.join("\n")
      # Investment contributions/market activity need their own classification
      # contract; arithmetic alone does not turn them into spendable income.
      raise Invalid if text.match?(/\bretirement\b|\binvestment statement\b/i)
      period = text.scan(/Statement (?:period|cycle):\s*(#{PERIOD_DATE})\s*(?:through|to|–|-)\s*(#{PERIOD_DATE})/i).uniq
      raise Invalid unless period.one?
      @start, @finish = period.sole.map { |value| value.include?("/") ? Date.strptime(value, "%m/%d/%Y") : Date.iso8601(value) }
      raise Invalid unless (@finish - @start).between?(0, 366)
      basis = if text.match?(/Beginning \+ credits - debits = ending|\b(?:checking|savings) account\b/i)
        "asset"
      elsif text.match?(/Prior balance \+ charges - payments\/refunds = new balance|\bcredit card (?:billing )?statement\b/i)
        "liability"
      end
      raise Invalid unless basis
      # Printed identifiers may have an alphabetic qualifier before the number.
      # Stop at the identifier token: a period/year on the same line is never
      # account evidence. After a qualifier ("Member since 2014") a bare short
      # number is not an account, so it must be masked or at least six digits.
      identifiers = text.scan(/\bAccount(?: number| no\.?)?:[ \t]*([a-z][a-z .#-]*[ \t]+)?((?:X{2,}|\*{2,})?\d{4,})(?=[ \t|\n]|$)/i)
        .filter_map { |qualifier, token| token if qualifier.nil? || token.match?(/\A(?:X{2,}|\*{2,})/i) || token.length >= 6 }.uniq
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
      @signed_asset = text.match?(/Credits positive; debits negative/i)
      # Two printed sign conventions contradict each other; never guess which applies.
      raise Invalid if @signed_card && @signed_asset
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
        if table_header?(line)
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
          raise RowError if in_table && line.any?
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

    def table_header?(line)
      texts = line.pluck(:text)
      texts.include?("Date") && texts.any? { |text| text.match?(/\A(?:Description|Payee|Details)\z/i) }
    end

    def page_type(page)
      page_lines = lines(page)
      return :transaction if page_lines.any? { |line| table_header?(line) }

      text = page_lines.map { |line| line.pluck(:text).join(" ") }.join("\n")
      # Positively identify supporting pages; unknown pages are never assumed
      # empty. A dated monetary line still requires repair even under a summary
      # heading, so printed rows cannot disappear with the supporting text.
      supporting = text.match?(/\b(?:account summary|statement summary|important disclosures|disclosure statement)\b/i)
      dated_movement = page_lines.any? do |line|
        line.any? { |run| run[:text].match?(DATE) } && line.any? { |run| run[:text].match?(MONEY) }
      end
      supporting && !dated_movement ? :non_transaction : :unreadable
    end

    def columns(line)
      header = {}
      line.each do |run|
        key = case run[:text].downcase
        when "date" then :date
        when "description", "payee", "details" then :description
        when "debit", "debits", "withdrawal", "withdrawals", "charge", "charges" then :debit
        when "credit", "credits", "deposit", "deposits", "payment", "payments" then :credit
        when "amount" then :amount
        when "balance" then :balance
        end
        raise RowError unless key && !header.key?(key)
        header[key] = run
      end
      raise RowError unless header[:date] && header[:description]
      signed_amount = (@signed_card && @account[:account_basis] == "liability") || (@signed_asset && @account[:account_basis] == "asset")
      raise RowError unless (header[:debit] && header[:credit] && !header[:amount]) || (signed_amount && header[:amount] && !header[:debit] && !header[:credit])
      header
    end

    def read_row(line, header, date_run, page, row)
      printed = printed_row(line, header, date_run, page, row)
      raise RowError unless printed.delete(:valid)
      type = event_type(printed[:raw_description], printed[:signed_amount_cents])
      raise RowError if type == "unknown" && printed[:row_kind] != "informational"
      printed.merge(event_type: type)
    end

    # Monetary evidence must survive classification failures and independently
    # unreadable cells. In particular a readable balance is retained even when
    # the amount or descriptor needs repair.
    def printed_row(line, header, date_run, page, row)
      fields = header.sort_by { |_key, run| run[:x] }
      values = Hash.new { |hash, key| hash[key] = [] }
      valid = true
      line.reject { |run| run == date_run }.each do |run|
        key = fields.reverse.find { |_name, label| run[:x] >= label[:x] - 32 }&.first
        valid = false unless key && key != :date
        values[key] << run[:text]
      end
      body = values.delete(:description).to_a.join(" ")
      valid = false if body.blank?
      amounts = values.transform_values do |texts|
        texts.one? ? money(texts.sole) : nil
      rescue Invalid
        nil
      end
      valid = false if amounts.values.any?(&:nil?)
      if header[:amount]
        signed = amounts[:amount] * (@signed_card ? -1 : 1) if amounts[:amount]
      else
        if (amounts.key?(:debit) ^ amounts.key?(:credit)) && amounts.values_at(:debit, :credit).compact.none?(&:negative?)
          signed = amounts.key?(:debit) ? amounts[:debit]&.-@ : amounts[:credit]
        end
      end
      valid = false unless signed
      pending = body.match?(/\[PENDING\]/i)
      { valid: valid, account_key: @account[:account_key], row_kind: pending ? "informational" : "posted",
        signed_amount_cents: signed, amount_column_cents: signed, posted_on: date(date_run[:text]),
        locator: { page: page, row: row }, merchant: MerchantNormalizer.call(mask(body)), raw_description: mask(body), evidence: mask(body),
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
      # The accounting contract's count covers ALL rows. A printed posted-only
      # count must not be relabelled to include pending authorizations.
      @account[:printed_row_count] = @posted_count if @posted_count == @rows.length
      @account[:header_evidence] += "; printed posted row count: #{@posted_count}; physical informational rows: #{@rows.length - posted.length}"
      accounting = AccountingContract.normalize({ contract_version: AccountingContract::VERSION, accounts: [ @account ], events: @rows, reported_row_count: @rows.length },
        coverage: { expected_page_count: @pages.length, processed_pages: (1..@pages.length).to_a })
      raise Invalid unless AccountingContract.preserves_printed_rows?(accounting, @rows)
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
      return "debt_payment" if body.match?(/(?:card|visa|loan)\s+payment|payment\s+(?:received|thank you)/i) || (@account[:account_basis] == "liability" && body.match?(/\Apayment\s+from\b/i))
      return "transfer" if body.match?(/\btransfer\b/i)
      return "cash_withdrawal" if body.match?(/\bATM\b|cash withdrawal/i)
      return "refund" if signed.positive? && body.match?(/refund|return|reversal/i)
      return "income" if signed.positive? && body.match?(/payroll|salary|direct deposit|ACH CREDIT|dividend/i)
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
      text = text.sub(/\A\$([+-])/) { "#{Regexp.last_match(1)}$" }
      match = text.match(MONEY) || raise(Invalid)
      cents = match[2].delete(",").to_i * 100 + match[3].to_i
      raise Invalid if cents > AccountingContract::CENT_LIMIT
      match[1] == "-" ? -cents : cents
    end

    def mask(text) = text.gsub(/\d{8,}/) { |value| "****#{value.last(4)}" }
    def rejected(reason) = Result.new(success: false, data: nil, error: reason, metadata: { reason: reason, parser_version: VERSION })
  end
end
