# frozen_string_literal: true

require "pdf/reader"

module FinancialDocuments
  # This is a qualified template parser, not a general bank-statement guesser.
  # Geometry, complete row census, printed totals and balances must all agree.
  class NativeStatementParser
    VERSION = "native_statement_geometry_v1"
    MAX_PAGES = 60
    MAX_RUNS = 60_000
    MONEY = /\A([+-]?)(?:\$)?((?:\d{1,3}(?:,\d{3})+|\d+))\.(\d{2})\z/
    SHORT_DATE = /\A\d{1,2}\/\d{1,2}\z/
    FULL_DATE = /\A\d{2}\/\d{2}\/\d{4}\z/
    MONTH = "(?:January|February|March|April|May|June|July|August|September|October|November|December)"
    MONTH_DATE = /\A#{MONTH} \d{1,2}, \d{4}\z/
    MONTH_PERIOD = /\A(#{MONTH} \d{1,2}, \d{4}) - (#{MONTH} \d{1,2}, \d{4})\z/
    Result = Data.define(:success, :data, :error, :metadata) do
      def success? = success == true
    end
    InvalidTemplate = Class.new(StandardError)

    def initialize(file_path:)
      @file_path = file_path
      @accounts, @events = [], []
      @financial_count = 0
      @consumed_money = []
      @regions = []
    end

    def call
      reader = PDF::Reader.new(@file_path)
      reject!("page_limit") unless reader.page_count.between?(1, MAX_PAGES)
      pages = reader.pages.map.with_index do |page, index|
        box = page.attributes.fetch(:MediaBox)
        reject!("page_geometry") unless box == [ 0, 0, 612, 792 ]
        reject!("page_geometry") unless page.attributes.fetch(:Rotate, 0) == 0 && page.attributes.fetch(:CropBox, box) == box
        { number: index + 1, runs: page.runs.map { |run| { text: run.text, x: run.x, y: run.y, finish: run.x + run.width } } }
      end
      parse_pages(pages)
    rescue InvalidTemplate => error
      rejected(error.message)
    rescue StandardError
      # PDF text/identifiers and exception content never enter generic logs.
      rejected("pdf_unreadable_or_unsupported")
    end

    private

    def parse_pages(pages)
      reject!("run_limit") if pages.sum { |page| page[:runs].length } > MAX_RUNS
      pages.each do |page|
        reject!("missing_native_text") if page[:runs].empty?
        reject!("invalid_run_geometry") unless page[:runs].all? { |run| run[:text].is_a?(String) && %i[x y finish].all? { |key| run[key].is_a?(Numeric) && run[key].finite? } }
      end
      first_text = pages.first[:runs].pluck(:text)
      if first_text.include?("Wells Fargo Everyday Checking")
        parse_wells_fargo(pages)
        template = "wells_fargo_everyday_checking_v1"
      elsif first_text.any? { |text| text.match?(/\AAccount Statement Summary \d{4}\z/) } && first_text.include?("APPLE ID")
        parse_apple_cash(pages)
        template = "apple_cash_monthly_sections_v1"
      else
        reject!("template_unrecognized")
      end
      reject!("event_limit") if @events.length > AccountingContract::MAX_EVENTS
      verify_region_census!(pages)
      accounting = AccountingContract.normalize({ contract_version: AccountingContract::VERSION, accounts: @accounts, events: @events },
        coverage: { expected_page_count: pages.length, processed_pages: (1..pages.length).to_a })
      Result.new(success: true, error: nil,
        data: { document_kind: "statement", document_date: @accounts.last[:period_end_on],
          period_start_on: @accounts.first[:period_start_on], period_end_on: @accounts.last[:period_end_on],
          summary: "Read #{@financial_count} financial rows and #{@events.length - @financial_count} informational rows from every statement page. Review classifications before approval.",
          confidence: "high", warnings: [ "Native template arithmetic verified; identity, classification and economic purpose still require participant review." ],
          items: [], transaction_drafts: [], source_accounting: accounting },
        metadata: { extraction_mode: "native_statement", parser_version: VERSION, template: template,
          page_count: pages.length, financial_row_count: @financial_count, informational_row_count: @events.length - @financial_count,
          printed_arithmetic_verified: true })
    end

    def parse_wells_fargo(pages)
      pages.each do |page|
        footer = one!(page[:runs].select { |run| run[:text].match?(/\APage \d+ of \d+\z/) }, "page_footer")[:text]
        reject!("page_footer") unless footer == "Page #{page[:number]} of #{pages.length}"
      end
      summary_page = one!(pages.select { |page| page[:runs].any? { |run| run[:text] == "Statement period activity summary" } }, "activity_summary")
      runs = summary_page[:runs]
      statement_dates = pages.first[:runs].filter_map { |run| month_date(run[:text]) }
      ending_date = one!(statement_dates.uniq, "statement_date")
      account_label = one!(runs.select { |run| run[:text] == "Account number:" }, "account_header")
      account_text = one!(runs.select { |run| near?(run[:y], account_label[:y], 1) && run[:x] > account_label[:finish] && run[:text].match?(/\A\d{8,20} \(primary account\)\z/) }, "account_header")[:text]
      identifier = account_text[/\d+/][-4, 4]
      reject!("account_identifier") unless identifier&.match?(/\A\d{4}\z/)
      start_label = one!(runs.select { |run| run[:text].match?(/\ABeginning balance on #{SHORT_DATE.source.delete_prefix('\A').delete_suffix('\z')}\z/) }, "opening_header")
      end_label = one!(runs.select { |run| run[:text].match?(/\AEnding balance on \d{1,2}\/\d{1,2}\z/) }, "closing_header")
      finish = short_date(end_label[:text].split.last, ending_date)
      reject!("statement_date") unless finish == ending_date
      start = short_date(start_label[:text].split.last, finish)
      reject!("period_geometry") unless (finish - start).between?(0, 45)
      credit_label = one!(runs.select { |run| run[:text] == "Deposits/Additions" }, "credit_header")
      debit_label = one!(runs.select { |run| run[:text] == "Withdrawals/Subtractions" }, "debit_header")
      account = { account_key: "wells_fargo_checking:#{identifier}", account_basis: "asset", label: "Wells Fargo Everyday Checking",
        masked_identifier: "****#{identifier}", period_start_on: start.iso8601, period_end_on: finish.iso8601,
        opening_balance_cents: aligned_money(runs, start_label, 328, tolerance: 3), closing_balance_cents: aligned_money(runs, end_label, 328, tolerance: 3),
        printed_credit_cents: aligned_money(runs, credit_label, 328, tolerance: 3), printed_debit_cents: aligned_money(runs, debit_label, 328, tolerance: 3).abs,
        header_evidence: "Wells Fargo Everyday Checking; printed activity summary and transaction totals", printed_row_count: nil }
      @accounts << account
      balance = account[:opening_balance_cents]
      movements = []
      totals_seen = false
      pages.each do |page|
        page_runs = page[:runs]
        dates = page_runs.select { |run| near?(run[:x], 61.5, 1) && run[:text].match?(SHORT_DATE) }.sort_by { |run| -run[:y] }
        totals = page_runs.select { |run| run[:text] == "Totals" && near?(run[:x], 61.5, 1) }
        reject!("duplicate_totals") if totals.many?
        total = totals.first
        header = page_runs.select { |run| run[:text] == "Date" && near?(run[:x], 63, 1.5) && page_runs.any? { |other| other[:text] == "Deposits/" && (other[:y] - run[:y]).between?(0, 11) && near?(other[:finish], 434, 1) } }
        reject!("table_header") if header.many?
        if header.one?
          validate_wf_columns!(page_runs, header.first)
          reject!("table_after_totals") if totals_seen
          @regions << { page: page[:number], top: header.first[:y] - 2, bottom: total ? total[:y] : 45, from: 390, date_x: 61.5, date_pattern: SHORT_DATE }
        elsif dates.any? || total
          reject!("table_header")
        end
        unpaid = page_runs.find { |run| run[:text] == "Items returned unpaid" }
        if unpaid
          unpaid_dates = dates.select { |date| date[:y] < unpaid[:y] }
          reject!("unpaid_table_missing") if unpaid_dates.empty?
          @regions << { page: page[:number], top: unpaid[:y] - 2, bottom: unpaid_dates.last[:y] - 18, from: 530, date_x: 61.5, date_pattern: SHORT_DATE }
        end
        markers = [ *dates, total ].compact.sort_by { |run| -run[:y] }
        markers.each_with_index do |marker, index|
          row = index + 1
          if marker == total
            reject!("duplicate_totals") if totals_seen
            reject!("printed_totals") unless aligned_money(page_runs, total, 434, tolerance: 1.5) == account[:printed_credit_cents] && aligned_money(page_runs, total, 503, tolerance: 1.5) == account[:printed_debit_cents]
            information(account, page, row, "Transaction history Totals", nil)
            totals_seen = true
            next
          end
          bottom = markers[index + 1]&.fetch(:y) || 45
          if total && marker[:y] < total[:y]
            reject!("unrecognized_financial_section") unless unpaid && marker[:y] < unpaid[:y]
            value = aligned_money(page_runs, marker, 563, tolerance: 3)
            information(account, page, row, "Items returned unpaid: #{description(page_runs, marker[:y], [ bottom, marker[:y] - 18 ].max, from: 90, to: 530)}", value,
              posted_on: short_date(marker[:text], finish).iso8601)
            next
          end
          reject!("date_outside_table") unless header.one? && marker[:y] < header.first[:y] && !totals_seen
          date = short_date(marker[:text], finish)
          reject!("date_outside_period") unless date.between?(start, finish)
          debit = aligned_money(page_runs, marker, 503, tolerance: 1.5, optional: true)
          credit = aligned_money(page_runs, marker, 434, tolerance: 1.5, optional: true)
          reject!("amount_columns") unless [ debit, credit ].compact.one? && (debit || credit).positive?
          signed = credit || -debit
          body = description(page_runs, marker[:y], bottom, from: 90, to: 395)
          reject!("description_missing") if body.blank?
          authorized = body.match(/\bauthorized on (\d{2}\/\d{2})\b/i)&.captures&.first
          authorized = short_date(authorized, date) if authorized
          reject!("authorization_date") if authorized && (date - authorized) > 60
          type = wf_type(body, signed)
          movements << event(account, page, row, date, signed, body, type, authorized: authorized)
          balance += signed
          printed_balance = aligned_money(page_runs, marker, 566, tolerance: 3, optional: true)
          reject!("running_balance") if printed_balance && printed_balance != balance
        end
      end
      reject!("totals_missing") unless totals_seen
      verify_movements!(account, movements)
    end

    def parse_apple_cash(pages)
      pages.each do |page|
        footer = one!(page[:runs].select { |run| run[:text].match?(/\APage \d+ \/ \d+\z/) }, "page_footer")[:text]
        reject!("page_footer") unless footer == "Page #{page[:number]} / #{pages.length}"
      end
      global = apple_header(pages.first[:runs])
      summary_title = one!(pages.first[:runs].select { |run| run[:text].match?(/\AAccount Statement Summary \d{4}\z/) }, "apple_summary_title")[:text]
      reject!("apple_summary_year") unless summary_title == "Account Statement Summary #{global[:finish].year}"
      account = nil
      movements = []
      balance = nil
      month_sections = []
      overview = apple_overview(pages.first[:runs], global)
      pages.drop(1).each do |page|
        runs = page[:runs]
        title = runs.find { |run| run[:text].match?(/\AAccount Statement #{MONTH} \d{4}\z/) }
        if title
          reject!("month_not_closed") if account
          reject!("apple_header_changed") unless apple_header(runs) == global
          month = Date.strptime(title[:text].delete_prefix("Account Statement "), "%B %Y")
          start = [ month, global[:start] ].max
          finish = [ month.end_of_month, global[:finish] ].min
          reject!("month_outside_period") if start > finish
          required = [ "Summary #{month.strftime('%B %Y')}", "Transactions #{month.strftime('%B %Y')}", "DATE", "DESCRIPTION", "ACCOUNT FEE", "AMOUNT", "BALANCE" ]
          reject!("apple_table_header") unless required.all? { |text| runs.any? { |run| run[:text] == text } }
          validate_apple_columns!(runs)
          opening = one!(runs.select { |run| run[:text] == "Starting Balance" && near?(run[:x], 38.75, 1) }, "apple_opening")
          ending = one!(runs.select { |run| run[:text] == "Ending Balance" && near?(run[:x], 38.75, 1) }, "apple_closing")
          incoming = one!(runs.select { |run| run[:text] == "Money In" }, "apple_credit")
          outgoing = one!(runs.select { |run| run[:text] == "Money Out" }, "apple_debit")
          reject!("apple_nonzero_fees") unless aligned_money(runs, incoming, 501, tolerance: 1) == 0 && aligned_money(runs, outgoing, 501, tolerance: 1) == 0
          credit = aligned_money(runs, incoming, 573.25, tolerance: 1)
          debit = aligned_money(runs, outgoing, 573.25, tolerance: 1)
          reject!("apple_summary_amounts") unless credit >= 0 && debit <= 0 && aligned_money(runs, incoming, 415, tolerance: 1) == credit && aligned_money(runs, outgoing, 415, tolerance: 1) == debit
          account = { account_key: "apple_cash:#{global[:identifier]}:#{month.strftime('%Y-%m')}", account_basis: "asset",
            label: "Apple Cash #{month.strftime('%B %Y')}", masked_identifier: "****#{global[:identifier]}",
            period_start_on: start.iso8601, period_end_on: finish.iso8601,
            opening_balance_cents: aligned_money(runs, opening, 573.25, tolerance: 1), closing_balance_cents: aligned_money(runs, ending, 573.25, tolerance: 1),
            printed_credit_cents: credit, printed_debit_cents: -debit, printed_row_count: nil,
            header_evidence: "Apple Cash; printed monthly summary within the printed overall statement period" }
          @accounts << account
          month_sections << [ finish, credit, -debit, account[:closing_balance_cents] ]
          balance = account[:opening_balance_cents]
          movements = []
        end
        dates = runs.select { |run| near?(run[:x], 38.75, 1) && run[:text].match?(FULL_DATE) }
        table_balances = runs.select { |run| %w[Starting\ Balance Ending\ Balance].include?(run[:text]) && near?(run[:x], 90.86, 1) }
        reject!("apple_rows_outside_month") if !account && (dates.any? || table_balances.any?)
        next unless account
        table_start = table_balances.find { |run| run[:text] == "Starting Balance" }
        table_end = table_balances.find { |run| run[:text] == "Ending Balance" }
        @regions << { page: page[:number], top: table_start ? table_start[:y] + 1 : 760,
          bottom: table_end ? table_end[:y] - 1 : 45, from: 240, date_x: 38.75, date_pattern: FULL_DATE }
        markers = [ *dates, *table_balances ].sort_by { |run| -run[:y] }
        markers.each_with_index do |marker, index|
          row = index + 1
          bottom = markers[index + 1]&.fetch(:y) || 45
          if table_balances.include?(marker)
            value = aligned_money(runs, marker, 573.25, tolerance: 1)
            reject!("apple_carry_balance") unless value == balance
            information(account, page, row, marker[:text], value)
            if marker[:text] == "Ending Balance"
              reject!("apple_closing_balance") unless value == account[:closing_balance_cents]
              verify_movements!(account, movements)
              account = nil
            end
            next
          end
          reject!("apple_date_after_closing") unless account
          date = Date.strptime(marker[:text], "%m/%d/%Y")
          reject!("date_outside_period") unless date.between?(Date.iso8601(account[:period_start_on]), Date.iso8601(account[:period_end_on]))
          block = runs.select { |run| run[:y] <= marker[:y] + 1 && run[:y] > bottom + 1 }
          amount_run = one!(block.select { |run| money_text?(run[:text]) && near?(run[:finish], 517.83, 1) }, "apple_row_amount")
          @consumed_money << amount_run
          signed = money(amount_run[:text])
          reject!("apple_amount_sign") unless amount_run[:text].match?(/\A[+-]\$/) && !signed.zero?
          reject!("apple_nonzero_row_fees") if block.any? { |run| money_text?(run[:text]) && near?(run[:finish], 461.98, 1) && money(run[:text]) != 0 }
          @consumed_money.concat(block.select { |run| money_text?(run[:text]) && near?(run[:finish], 461.98, 1) })
          body = description(runs, marker[:y], bottom, from: 90, to: 405)
          type = apple_type(body, signed)
          funding = apple_funding(block, account, signed)
          movements << event(account, page, row, date, signed, body, type, funding: funding)
          balance += signed
          printed_balance = one!(block.select { |run| money_text?(run[:text]) && near?(run[:finish], 573.25, 1) }, "apple_row_balance")
          @consumed_money << printed_balance
          reject!("apple_running_balance") unless money(printed_balance[:text]) == balance && near?(printed_balance[:y], amount_run[:y], 1)
        end
      end
      reject!("month_not_closed") if account
      reject!("apple_overview_disagrees") unless month_sections == overview[:months] && @accounts.first[:opening_balance_cents] == overview[:opening] && @accounts.last[:closing_balance_cents] == overview[:closing]
      @accounts.each_cons(2) { |first, second| reject!("apple_month_continuity") unless Date.iso8601(first[:period_end_on]) + 1 == Date.iso8601(second[:period_start_on]) && first[:closing_balance_cents] == second[:opening_balance_cents] }
    end

    def apple_header(runs)
      identifier = one!(runs.select { |run| run[:text].match?(/\A[•*]{4}\d{4}\z/) }, "apple_identifier")[:text][-4, 4]
      period = one!(runs.select { |run| run[:text].match?(MONTH_PERIOD) }, "apple_period")[:text].match(MONTH_PERIOD)
      { identifier: identifier, start: Date.strptime(period[1], "%B %d, %Y"), finish: Date.strptime(period[2], "%B %d, %Y") }
    end

    def apple_overview(runs, global)
      opening = one!(runs.select { |run| run[:text] == "Starting Balance" && near?(run[:x], 38.75, 1) }, "overview_opening")
      closing = one!(runs.select { |run| run[:text] == "Ending Balance" && near?(run[:x], 38.75, 1) }, "overview_closing")
      months = runs.filter_map do |run|
        date = month_date(run[:text])
        next unless date && near?(run[:x], 38.75, 1)
        reject!("overview_nonzero_fees") unless aligned_money(runs, run, 447, tolerance: 1) == 0
        credit, debit = aligned_money(runs, run, 365.37, tolerance: 1), aligned_money(runs, run, 502.52, tolerance: 1)
        reject!("overview_direction") unless credit >= 0 && debit <= 0
        [ date, credit, -debit, aligned_money(runs, run, 573.25, tolerance: 1) ]
      end
      reject!("overview_period") unless months.any? && months.last.first == global[:finish] && global[:start] <= months.first.first
      { opening: aligned_money(runs, opening, 573.25, tolerance: 1), closing: aligned_money(runs, closing, 573.25, tolerance: 1), months: months }
    end

    def apple_funding(block, account, signed)
      total = block.find { |run| run[:text] == "Total Payment" }
      return [] unless total
      cash = one!(block.select { |run| run[:text] == "From Apple Cash" }, "apple_funding_cash")
      printed_total = aligned_money(block, total, 395.61, tolerance: 1)
      printed_cash = aligned_money(block, cash, 395.61, tolerance: 1)
      external = one!(block.select { |run| run[:text].match?(/\A\d{4}\)\z/) && near?(run[:x], 241.73, 1) }, "apple_funding_identifier")
      reject!("apple_funding_mask") unless block.any? { |run| run[:text] == "NATIONAL ASSOCIATION (••••" && near?(run[:x], external[:x], 1) && near?(run[:y], external[:y] + 9, 1) }
      external_amount = aligned_money(block, external, 395.61, tolerance: 1)
      reject!("apple_split_funding") unless signed < 0 && printed_cash == -signed && printed_total.positive? && external_amount < 0 && printed_cash - external_amount == printed_total && block.any? { |run| run[:text] == "From WELLS FARGO BANK" }
      [ { account_key: account[:account_key], amount_cents: printed_cash },
        { account_key: "wells_fargo_external:#{external[:text][/\d{4}/]}", amount_cents: -external_amount } ]
    end

    def validate_wf_columns!(runs, header)
      { "Deposits/" => 434, "Withdrawals/" => 502, "balance" => 566 }.each do |text, finish|
        reject!("table_column_geometry") unless runs.any? { |run| run[:text] == text && near?(run[:finish], finish, 1.5) && (run[:y] - header[:y]).between?(-1, 11) }
      end
    end

    def validate_apple_columns!(runs)
      { "DATE" => 38.75, "DESCRIPTION" => 90.86, "ACCOUNT FEE" => 430.79, "AMOUNT" => 498.17, "BALANCE" => 552.76 }.each do |text, x|
        reject!("apple_column_geometry") unless runs.any? { |run| run[:text] == text && near?(run[:x], x, 1) && near?(run[:y], 435.15, 1) }
      end
    end

    def wf_type(body, signed)
      return "fee" if body.match?(/\b(?:Overdraft Fee|Monthly Service Fee|ATM Fee|Non-WF ATM|Returned Item Fee)\b/i) && signed < 0
      return "cash_withdrawal" if body.match?(/\bATM Withdrawal\b/i) && signed < 0
      return "transfer" if body.match?(/\b(?:Money Transfer|Online Transfer|Zelle|Transfer From|Transfer To)\b/i)
      return "debt_payment" if body.match?(/\b(?:Credit Card|Card Payment|Loan Payment)\b/i) && signed < 0
      return "refund" if body.match?(/\b(?:Purchase Return|Refund)\b/i) && signed > 0
      return "purchase" if body.match?(/\b(?:Purchase authorized|Recurring Payment authorized)\b/i) && signed < 0
      return "income" if body.match?(/\b(?:Payroll|Salary|Direct Deposit)\b/i) && signed > 0
      return "interest" if body.match?(/\bInterest Payment\b/i)

      "unknown"
    end

    def apple_type(body, _signed)
      return "transfer" if body.match?(/\b(?:Added to Balance|Payment to|Received from)\b/i)
      return "adjustment" if body.include?("Daily Cash from Apple Card")
      # Merchant/location alone does not prove whether this is a purchase/refund.
      "unknown"
    end

    def event(account, page, row, date, signed, body, type, authorized: nil, funding: [])
      reject!("date_order") if @last_date && @last_date > date
      @last_date = date
      @financial_count += 1
      attributes = { account_key: account[:account_key], row_kind: "posted", event_type: type, signed_amount_cents: signed,
        amount_column_cents: signed, posted_on: date.iso8601, authorized_on: authorized&.iso8601,
        locator: { page: page[:number], row: row }, merchant: body, raw_description: body, evidence: body, funding_components: funding }
      @events << attributes
      attributes
    end

    def information(account, page, row, body, amount, posted_on: nil)
      @events << { account_key: account[:account_key], row_kind: "informational", event_type: "unknown", signed_amount_cents: amount,
        posted_on: posted_on, locator: { page: page[:number], row: row }, raw_description: body, evidence: body }
    end

    def verify_movements!(account, movements)
      credit = movements.sum { |row| [ row[:signed_amount_cents], 0 ].max }
      debit = movements.sum { |row| [ -row[:signed_amount_cents], 0 ].max }
      reject!("printed_arithmetic") unless credit == account[:printed_credit_cents] && debit == account[:printed_debit_cents] && account[:opening_balance_cents] + credit - debit == account[:closing_balance_cents]
    end

    def description(runs, top, bottom, from:, to:)
      runs.select { |run| run[:x] >= from && run[:x] < to && run[:y] <= top + 1 && run[:y] > bottom + 1 }
        .sort_by { |run| [ -run[:y], run[:x] ] }.pluck(:text).join(" ").squish
        .gsub(/\d{8,}/) { |identifier| "****#{identifier[-4, 4]}" }
    end

    def aligned_money(runs, label, finish, tolerance:, optional: false)
      candidates = runs.select { |run| money_text?(run[:text]) && near?(run[:finish], finish, tolerance) && near?(run[:y], label[:y], 1) }
      return nil if optional && candidates.empty?
      candidate = one!(candidates, "money_column")
      @consumed_money << candidate
      money(candidate[:text])
    end

    def verify_region_census!(pages)
      pages.each do |page|
        page[:runs].each do |run|
          next unless run[:x].between?(30, 90) && run[:text].match?(/\A\d{1,2}\//)
          region = @regions.find { |candidate| candidate[:page] == page[:number] && run[:y].between?(candidate[:bottom], candidate[:top]) }
          reject!("date_outside_recognized_section") unless region && near?(run[:x], region[:date_x], 1) && run[:text].match?(region[:date_pattern])
        end
      end
      @regions.each do |region|
        page = pages.find { |candidate| candidate[:number] == region[:page] }
        runs = page[:runs].select { |run| run[:y].between?(region[:bottom], region[:top]) }
        runs.each do |run|
          if run[:x].between?(30, 90) && run[:text].match?(/\A\d{1,2}\//)
            reject!("date_column_census") unless near?(run[:x], region[:date_x], 1) && run[:text].match?(region[:date_pattern])
          end
          if run[:x] >= region[:from] && run[:text].match?(/\A(?:[+-]?\$|[+-]?\d[\d,]*\.)/)
            reject!("unrepresented_amount_column") unless money_text?(run[:text]) && @consumed_money.include?(run)
          end
        end
      end
    end

    # Wells Fargo prints a space after the debit sign. Never collapse spaces
    # inside digits: malformed source numbers must not become valid amounts.
    def canonical_money(text) = text.sub(/\A([+-]) /, '\\1')

    def money_text?(text) = canonical_money(text).match?(MONEY)

    def money(text)
      match = canonical_money(text).match(MONEY) || reject!("invalid_money")
      cents = match[2].delete(",").to_i * 100 + match[3].to_i
      reject!("money_limit") if cents > AccountingContract::CENT_LIMIT
      match[1] == "-" ? -cents : cents
    end

    def short_date(text, reference)
      month, day = text.split("/").map(&:to_i)
      date = Date.new(reference.year, month, day)
      date = Date.new(reference.year - 1, month, day) if date > reference
      date
    rescue ArgumentError
      reject!("invalid_date")
    end

    def month_date(text)
      Date.strptime(text, "%B %d, %Y") if text.match?(MONTH_DATE)
    end

    def near?(number, expected, tolerance) = (number - expected).abs <= tolerance

    def one!(values, code)
      reject!(code) unless values.one?
      values.first
    end

    def reject!(code) = raise(InvalidTemplate, code)

    def rejected(code)
      Result.new(success: false, data: nil, error: code,
        metadata: { extraction_mode: "native_statement_rejected", parser_version: VERSION, reason: code })
    end
  end
end
