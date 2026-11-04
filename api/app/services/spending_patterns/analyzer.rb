module SpendingPatterns
  # Observations, never an assertion of complete account coverage or affordability.
  # Read approved source heads directly and exclude their projected transactions,
  # so a statement purchase cannot appear twice.
  class Analyzer
    def initialize(household, today: Time.current.in_time_zone("Pacific/Guam").to_date, from: nil, to: nil)
      @household, @today, @from, @to = household, today, from, to
    end

    def call
      revision_ids = FinancialExtractionRevision.where(household: @household,
        financial_document_import_id: @household.financial_document_imports.current_picture.select(:id)).pluck(:id)
      reviewed = FinancialDocuments::SourceReview::ApprovedSourceReader.new(@household).call(revision_ids: revision_ids, current_financial_picture: true)
      eligible_ids = reviewed[:canonical_rows].select { |row| row[:spending_eligible] }.map { |row| row[:id] }
      source = SourceReviewVersion.where(household_id: @household.id, id: reviewed[:canonical_rows].map { |row| row[:id] })
        .includes(:budget_category, source_account_identity_version: :source_tracked_account).to_a
      actuals_scope = @household.household_transactions.where(status: %w[confirmed reconciled], financial_source_event_id: nil)
      dates = source.filter_map(&:posted_on) + actuals_scope.pluck(:occurred_on)
      last = dates.select { |date| date < @today.beginning_of_month }.max
      finish = @to ? Date.iso8601(@to.to_s) : (last || @today.prev_month).end_of_month
      start = @from ? Date.iso8601(@from.to_s) : finish.beginning_of_month - 2.months
      raise ArgumentError, "Choose a past spending window of up to one year" unless start <= finish && finish <= @today && (finish - start).to_i <= 366
      selected_source = source.select { |row| row.posted_on&.between?(start, finish) }
      selected_actuals = actuals_scope.where(occurred_on: start..finish)
        .includes(transaction_splits: :budget_category).to_a
      rows = selected_source.select { |row| eligible_ids.include?(row.id) }.map { |row| source_row(row) } + selected_actuals.map { |row| actual_row(row) }
      RefundNetting.call(rows, source: selected_source, reviewed: reviewed)
      rows.reject! { |row| row[:amount_cents].zero? }
      # All source classifications inform observed coverage; income-only months
      # are not represented as months with no spending.
      months = (start.beginning_of_month..finish).select { |day| day.day == 1 }.map do |month|
        count = rows.count { |row| row[:date].beginning_of_month == month }
        { month: month.strftime("%Y-%m"), purchase_count: count, spending_cents: count.positive? ? rows.select { |row| row[:date].beginning_of_month == month }.sum { |row| row[:amount_cents] } : nil }
      end
      merchants = group_totals(rows, :merchant)
      discretionary = rows.flat_map { |row| row[:splits].select { |split| split[:discretionary] }.map { |split| row.merge(amount_cents: split[:amount_cents], category: split[:name], category_id: split[:category_id]) } }
      flexible_merchants = group_totals(discretionary, :merchant)
      categories = group_totals(discretionary, :category)
      choices = flexible_merchants.first(3).map.with_index do |row, index|
        { id: "choice-#{index + 1}", label: "Cut back on #{row[:label]}", merchant: row[:label],
          monthly_impact_cents: (row[:monthly_average_cents] / 2.0).floor,
          description: "Try spending half as much at #{row[:label]}", assumption: "Half of the average in months with recorded purchases; an estimate, not saved money" }
      end.select { |row| row[:monthly_impact_cents].positive? }
      { window: { start_on: start.iso8601, end_on: finish.iso8601 },
        coverage: { status: "partial", months: months, accounts: selected_source.map { |row| row.source_tracked_account.label }.uniq.sort,
          account_completeness: "unknown", note: "Only confirmed purchases and reviewed statement rows are included. Reviewed linked and same-merchant refunds are deducted; missing months, accounts and unreviewed uploads may change these patterns." },
        purchase_count: rows.length, observed_spending_cents: rows.any? ? rows.sum { |row| row[:amount_cents] } : nil,
        merchants: merchants, discretionary_merchants: flexible_merchants, discretionary_categories: categories,
        small_purchase_clusters: clusters(rows), possible_subscriptions: recurring(rows), candidate_changes: choices,
        savings_inferred: false }
    end

    private

    def source_row(row)
      { source_version_id: row.id, date: row.posted_on, merchant: FinancialDocuments::MerchantNormalizer.call(row.merchant.presence || "Unnamed purchase"), amount_cents: row.purchase_amount_cents || -row.signed_amount_cents,
        splits: [ split(row.budget_category, row.purchase_amount_cents || -row.signed_amount_cents) ] }
    end

    def actual_row(row)
      { date: row.occurred_on, merchant: FinancialDocuments::MerchantNormalizer.call(row.merchant), amount_cents: row.total_amount_cents,
        splits: row.transaction_splits.map { |value| split(value.budget_category, value.amount_cents) } }
    end

    def split(category, amount)
      { category_id: category&.id, name: category&.name || "Uncategorized", amount_cents: amount, discretionary: category&.stack_key == "discretionary" }
    end

    def group_totals(rows, key)
      rows.group_by { |row| row[key].to_s.unicode_normalize(:nfkc).squish.downcase }.map do |_, group|
        months = group.map { |row| row[:date].strftime("%Y-%m") }.uniq
        total = group.sum { |row| row[:amount_cents] }
        { label: group.first[key], total_cents: total, purchase_count: group.length,
          observed_months: months.sort, monthly_average_cents: total.div(months.length) }
      end.sort_by { |row| [ -row[:total_cents], row[:label] ] }
    end

    def clusters(rows)
      small = rows.select { |row| row[:amount_cents] <= 2_500 }
      groups = small.group_by { |row| row[:date].strftime("%A") }.map { |label, group| [ label, group ] }
      groups += small.group_by { |row| row[:date].day <= 10 ? "the first ten days of the month" : row[:date].day <= 20 ? "the middle of the month" : "the end of the month" }.to_a
      groups += [ [ "Friday through Sunday", small.select { |row| [ 5, 6, 0 ].include?(row[:date].wday) } ] ]
      groups.filter_map do |label, group|
        next if group.length < 3 || group.map { |row| row[:date] }.uniq.length < 2
        { label: label, purchase_count: group.length, total_cents: group.sum { |row| row[:amount_cents] }, threshold_cents: 2_500 }
      end.sort_by { |row| [ -row[:purchase_count], row[:label] ] }.first(4)
    end

    def recurring(rows)
      rows.group_by { |row| row[:merchant].downcase.squish }.filter_map do |_, group|
        # A repeated retail purchase is a habit, not a subscription. Only flag
        # subscription wording or a participant-labelled subscription category.
        subscription_label = group.first[:merchant].match?(/\b(?:subscriptions?|membership|stream(?:ing)?\s+service|netflix|spotify|gym|software|phone\s+plan|internet\s+plan)\b/i) ||
          group.any? { |row| row[:splits].any? { |split| split[:name].match?(/\b(?:subscriptions?|memberships?|streaming|software|gym|phone\s+plan|internet\s+plan)\b/i) } }
        next unless subscription_label
        next unless group.length >= 3 && group.map { |row| row[:date].strftime("%Y-%m") }.uniq.length >= 3
        amounts = group.map { |row| row[:amount_cents] }.sort
        median = amounts[amounts.length / 2]
        next unless amounts.all? { |amount| (amount - median).abs <= [ 25, median / 100 ].max }
        next unless group.sort_by { |row| row[:date] }.each_cons(2).all? { |first, second| (26..35).cover?((second[:date] - first[:date]).to_i) }
        { merchant: group.first[:merchant], typical_amount_cents: median, observed_payments: group.length, confirmed_subscription: false }
      end.sort_by { |row| [ -row[:typical_amount_cents], row[:merchant] ] }
    end
  end
end
