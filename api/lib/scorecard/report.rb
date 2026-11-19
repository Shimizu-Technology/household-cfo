module Scorecard
  class Report
    def initialize(household:, answer_key:, simulator:, documents:)
      @household, @key, @simulator, @documents = household, answer_key, simulator, documents
    end

    def call
      @transactions = @household.household_transactions.where(status: %w[confirmed reconciled]).includes(transaction_splits: :budget_category).to_a
      @reviewed = FinancialDocuments::SourceReview::ApprovedSourceReader.new(@household).call(revision_ids: FinancialExtractionRevision.where(household: @household).pluck(:id))
      @income = @reviewed[:canonical_rows].select { |row| row[:account_identity_current] && row[:event_type] == "income" }
      months = @key.expected_months(@documents).to_h do |month, expected|
        [ month, month_report(month, expected) ]
      end
      annual = aggregate(months.values)
      { "schema_version" => 1, "answer_key" => @key.data.fetch("schema_version"), "document_count" => @documents.length,
        "months" => months, "annual" => annual,
        "distinct_purchase_groups" => @key.data.fetch("events").filter_map { |event| event["distinct_purchase_group"] }.uniq.to_h do |group|
          events = @key.data.fetch("events").select { |event| event["distinct_purchase_group"] == group && @documents.any? { |doc| doc.fetch("lines").any? { |line| line["event_id"] == event["event_id"] } } }
          counted = @transactions.count { |row| (line = transaction_answer(row)) && @key.event(line)["distinct_purchase_group"] == group }
          [ group, { "expected_count" => events.length, "actual_count" => counted, "error_count" => counted - events.length } ]
        end,
        "source_coverage" => { "expected_rows" => @documents.sum { |doc| doc.fetch("lines").length },
          "extracted_rows" => @simulator.row_answers.length,
          "missing_rows" => @documents.sum { |doc| doc.fetch("lines").length } - @simulator.row_answers.values.compact.map { |line| line.fetch("line_id") }.uniq.length,
          "unrecognized_rows" => @simulator.row_answers.values.count(nil) },
        "targets" => { "monthly_spending_within_one_percent" => months.values.all? { |row| row.dig("total_spending", "absolute_error_percent") <= 1 },
          "zero_double_counts" => annual["double_counts"].zero?, "zero_transfer_leakage" => annual["transfer_leakage_cents"].zero?,
          "decisions_under_200" => annual["decisions"] < 200 } }
    end

    def self.table(report)
      lines = [ "Month     Spending     Expected      Error  Income       Doubles Leakage Decisions" ]
      (report.fetch("months").to_a + [ [ "Annual", report.fetch("annual") ] ]).each do |month, row|
        lines << format("%-7s %11.2f %11.2f %9.2f %11.2f %7d %7.2f %9d", month,
          row.dig("total_spending", "actual_cents") / 100.0, row.dig("total_spending", "expected_cents") / 100.0,
          row.dig("total_spending", "error_cents") / 100.0, row.dig("income", "actual_cents") / 100.0,
          row["double_counts"], row["transfer_leakage_cents"] / 100.0, row["decisions"])
      end
      lines << "Targets: #{report.fetch('targets').map { |name, passed| "#{name}=#{passed ? 'PASS' : 'FAIL'}" }.join(', ')}"
      lines.join("\n")
    end

    private

    def month_report(month, expected)
      transactions = @transactions.select { |row| row.occurred_on.strftime("%Y-%m") == month }
      actual_categories = transactions.flat_map(&:transaction_splits).group_by { |split| split.budget_category.name }.transform_values { |splits| splits.sum(&:amount_cents) }
      year, number = month.split("-").map(&:to_i)
      # Exercise the Budget presenter, not a scorecard-owned spending formula.
      budget = HouseholdFinance::AnnualBudgetManager.new(@household, year: year).plan_data
      budget_categories = budget[:rows].to_h { |row| [ row[:name], HouseholdFinance::Money.cents(row[:months][number - 1][:actual]) ] }
      raise "Scorecard disagrees with Budget" unless actual_categories.all? { |name, cents| budget_categories[name] == cents }
      categories = (expected.fetch("spending_by_category_cents").keys + actual_categories.keys).uniq.to_h do |name|
        [ name, metric(actual_categories.fetch(name, 0), expected.fetch("spending_by_category_cents").fetch(name, 0)) ]
      end
      income = @income.select { |row| row[:posted_on]&.start_with?(month) }
      counted_answers = transactions.filter_map { |row| transaction_answer(row) } + income.filter_map { |row| @simulator.row_answers[row[:event_id]] }
      # Twin event IDs can be interchanged: the pair has capacity two.
      double_counts = counted_answers.group_by { |line| economic_key(@key.event(line)) }.sum do |key, group|
        capacity = key.start_with?("group:") ? @key.data.fetch("events").count { |event| economic_key(event) == key } : 1
        [ group.length - capacity, 0 ].max
      end
      leaked_spending = transactions.select { |row| transfer?(transaction_answer(row)) }.sum(&:total_amount_cents)
      leaked_income = income.select { |row| transfer?(@simulator.row_answers[row[:event_id]]) }.sum { |row| row[:signed_amount_cents].abs }
      analysis = SpendingPatterns::Analyzer.new(@household, today: Date.current, from: Date.new(year, number, 1), to: Date.new(year, number, 1).end_of_month).call
      receipts = receipt_report(month)
      decisions = @simulator.decisions.fetch(month, {})
      { "total_spending" => metric(transactions.sum(&:total_amount_cents), expected.fetch("total_spending_cents")),
        "spending_by_category" => categories, "income" => metric(income.sum { |row| row[:signed_amount_cents] }, expected.fetch("income_cents")),
        "analyzer_spending" => metric(analysis[:observed_spending_cents].to_i, expected.fetch("total_spending_cents")),
        "double_counts" => double_counts, "transfer_leakage_cents" => leaked_spending + leaked_income,
        "transfer_leakage_spending_cents" => leaked_spending, "transfer_leakage_income_cents" => leaked_income,
        "receipts" => receipts, "decisions" => decisions.values.sum, "decisions_by_kind" => decisions }
    end

    def transaction_answer(row) = @simulator.row_answers[row.financial_source_event_id] || @simulator.transaction_answers[row.id]

    def economic_key(event) = event["distinct_purchase_group"] ? "group:#{event['distinct_purchase_group']}" : event.fetch("event_id")
    def transfer?(line) = line && @key.event(line).fetch("event_kind").in?(%w[transfer_own_accounts card_payment])

    def receipt_report(month)
      docs = @documents.select { |doc| doc["receipt"] && doc.fetch("period").fetch("start_on").start_with?(month) }
      docs.map do |doc|
        expected = doc.fetch("receipt")
        event_id = expected.fetch("matching_bank_event_id")
        document = @household.financial_document_imports.find_by!(filename: File.basename(doc.fetch("path")))
        counted = @transactions.select { |row| transaction_answer(row)&.fetch("event_id") == event_id || row.source_import_id == document.id }
        { "new_money" => metric(counted.sum(&:total_amount_cents), expected.fetch("new_money_cents")),
          "matched_to_bank" => @simulator.receipt_observations.fetch(doc.fetch("path")).fetch("matched"),
          "extracted_new_money" => metric(@simulator.receipt_observations.fetch(doc.fetch("path")).fetch("extracted_new_money_cents"), expected.fetch("new_money_cents")),
          "category_allocation_error_cents" => expected.fetch("expected_category_allocations").sum do |allocation|
            actual = counted.flat_map(&:transaction_splits).select { |split| split.budget_category.name == allocation.fetch("category") }.sum(&:amount_cents)
            (actual - allocation.fetch("spending_cents")).abs
          end }
      end
    end

    def aggregate(months)
      keys = %w[total_spending income analyzer_spending]
      result = keys.to_h { |key| [ key, metric(months.sum { |row| row.dig(key, "actual_cents") }, months.sum { |row| row.dig(key, "expected_cents") }) ] }
      result["spending_by_category"] = months.flat_map { |row| row.fetch("spending_by_category").keys }.uniq.to_h do |name|
        values = months.filter_map { |row| row.dig("spending_by_category", name) }
        [ name, metric(values.sum { |row| row["actual_cents"] }, values.sum { |row| row["expected_cents"] }) ]
      end
      %w[double_counts transfer_leakage_cents decisions].each { |key| result[key] = months.sum { |row| row.fetch(key) } }
      receipts = months.flat_map { |row| row.fetch("receipts") }
      result.merge("receipt_extraction_absolute_error_cents" => receipts.sum { |row| row.dig("extracted_new_money", "error_cents").abs }, "receipt_count" => receipts.length, "receipt_matches" => receipts.count { |row| row["matched_to_bank"] },
        "receipt_new_money_absolute_error_cents" => receipts.sum { |row| row.dig("new_money", "error_cents").abs },
        "receipt_category_allocation_error_cents" => receipts.sum { |row| row["category_allocation_error_cents"] })
    end

    def metric(actual, expected)
      error = actual - expected
      { "actual_cents" => actual, "expected_cents" => expected, "error_cents" => error,
        "absolute_error_percent" => expected.zero? ? (actual.zero? ? 0.0 : 100.0) : (error.abs * 100.0 / expected.abs).round(4) }
    end
  end
end
