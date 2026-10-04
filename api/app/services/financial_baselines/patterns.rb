module FinancialBaselines
  class Patterns
    def initialize(rows, refunds, eligibility)
      @rows, @refunds, @eligibility = rows, refunds, eligibility.index_by { |row| row[:budget_category_id] }
    end

    def call
      gross = expenses.sum { |row| row[:purchase_amount_cents] }
      credits = refunds.sum { |row| row[:amount_cents] }
      prior = refunds.select { |row| row[:prior_window_purchase] }.sum { |row| row[:amount_cents] }
      eligible_gross = expenses.sum { |row| row[:splits].select { |split| eligibility[split[:budget_category_id]]&.dig(:eligible) }.sum { |split| split[:amount_cents] } }
      eligible_prior_refunds = refunds.select { |refund| refund[:prior_window_purchase] && eligibility[refund[:budget_category_id]]&.dig(:eligible) }.sum { |refund| refund[:amount_cents] }
      eligible_refunds = refunds.select { |refund| eligibility[refund[:budget_category_id]]&.dig(:eligible) }.sum { |refund| refund[:amount_cents] }
      { gross_spending_cents: gross, allocated_refunds_cents: credits, prior_window_refunds_cents: prior,
        net_spending_cents: gross - credits, same_window_net_spending_cents: gross - credits + prior,
        eligible_gross_spending_cents: eligible_gross, eligible_net_spending_cents: eligible_gross - eligible_refunds, prior_window_eligible_refunds_cents: eligible_prior_refunds,
        comparable_eligible_spending_cents: eligible_gross - eligible_refunds + eligible_prior_refunds,
        expense_count: expenses.length, source_row_count: rows.length, unallocated_refund_cents: rows.select { |row| row[:classification] == "refund" }.sum { |row| row[:signed_amount_cents] } - credits,
        transfers: movement_summary("transfer"), debt_payments: movement_summary("debt_payment"), cash_withdrawals: movement_summary("cash_withdrawal"),
        income_cents: rows.select { |row| row[:classification] == "income" }.sum { |row| row[:signed_amount_cents] },
        merchants: merchant_patterns, categories: category_patterns, months: monthly_patterns,
        recurrence_inferred: false, savings_inferred: false }
    end

    private

    attr_reader :rows, :refunds, :eligibility
    def expenses = rows.select { |row| row[:expense] }
    def merchant_key(value) = value.to_s.unicode_normalize(:nfkc).squish.downcase

    def movement_summary(type)
      selected = rows.select { |row| row[:classification] == type }
      { count: selected.length, outflow_cents: selected.sum { |row| [ -row[:signed_amount_cents].to_i, 0 ].max }, inflow_cents: selected.sum { |row| [ row[:signed_amount_cents].to_i, 0 ].max } }
    end

    def merchant_patterns
      keys = (expenses.map { |row| merchant_key(row[:merchant]) } + refunds.map { |row| merchant_key(row[:merchant]) }).uniq
      keys.map do |key|
        purchases = expenses.select { |row| merchant_key(row[:merchant]) == key }
        reversed = refunds.select { |row| merchant_key(row[:merchant]) == key }
        gross = purchases.sum { |row| row[:purchase_amount_cents] }
        credits = reversed.sum { |row| row[:amount_cents] }
        { merchant: purchases.first&.dig(:merchant) || reversed.first[:merchant], frequency: purchases.length,
          gross_cents: gross, refunds_cents: credits, net_cents: gross - credits,
          prior_window_refunds_cents: reversed.select { |row| row[:prior_window_purchase] }.sum { |row| row[:amount_cents] },
          observed_dates: purchases.pluck(:posted_on).uniq.sort, recurrence_inferred: false, optional_spending_inferred: false }
      end.sort_by { |row| [ -row[:net_cents], merchant_key(row[:merchant]) ] }
    end

    def category_patterns
      eligibility.values.map do |category|
        id = category[:budget_category_id]
        purchases = expenses.select { |row| row[:splits].any? { |split| split[:budget_category_id] == id } }
        gross = purchases.sum { |row| row[:splits].select { |split| split[:budget_category_id] == id }.sum { |split| split[:amount_cents] } }
        reversed = refunds.select { |row| row[:budget_category_id] == id }
        credits = reversed.sum { |row| row[:amount_cents] }
        category.merge(frequency: purchases.length, gross_cents: gross, refunds_cents: credits, net_cents: gross - credits,
          prior_window_refunds_cents: reversed.select { |row| row[:prior_window_purchase] }.sum { |row| row[:amount_cents] })
      end.sort_by { |row| [ -row[:net_cents], row[:name] ] }
    end

    def monthly_patterns
      months = (rows.pluck(:posted_on) + refunds.pluck(:posted_on)).compact.map { |date| date[0, 7] }.uniq.sort
      months.map do |month|
        purchases = expenses.select { |row| row[:posted_on].start_with?(month) }
        reversed = refunds.select { |row| row[:posted_on].start_with?(month) }
        gross = purchases.sum { |row| row[:purchase_amount_cents] }
        credits = reversed.sum { |row| row[:amount_cents] }
        { month: month, gross_cents: gross, refunds_cents: credits, net_cents: gross - credits,
          prior_window_refunds_cents: reversed.select { |row| row[:prior_window_purchase] }.sum { |row| row[:amount_cents] }, frequency: purchases.length,
          categories: eligibility.values.map do |category|
            id = category[:budget_category_id]
            amount = purchases.sum { |row| row[:splits].select { |split| split[:budget_category_id] == id }.sum { |split| split[:amount_cents] } }
            credit = reversed.select { |row| row[:budget_category_id] == id }.sum { |row| row[:amount_cents] }
            { budget_category_id: id, gross_cents: amount, refunds_cents: credit, net_cents: amount - credit }
          end }
      end
    end
  end
end
