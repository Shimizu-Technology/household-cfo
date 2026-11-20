module SpendingPatterns
  # Observations, never an assertion of complete account coverage or affordability.
  # Read approved source heads directly and exclude their projected transactions,
  # so a statement purchase cannot appear twice.
  class Analyzer
    # The Household CFO Method never suggests cutting the roof, utilities, medical care, children or family
    # (Mrs. Mel: "I would never tell someone… don't take care of your family"). These stay in spending totals
    # but are not flexible spending and are never offered as a cut.
    PROTECTED_CATEGORY = /\b(?:medical|medicine|medications?|meds|doctors?|dental|dentist|health|pharmacy|prescriptions?|hospital|clinic|therapy|child(?:ren)?|childcare|daycare|kids?|baby|babies|school|tuition|daughters?|sons?|family|mom|mother|dad|father|parents?|grandparents?|rent|mortgage|housing|utilities|utility|power|water|electric(?:ity)?)\b/i
    # Money sent to a person is usually support or paying someone back, not a store habit to halve.
    PERSON_TRANSFER = /\A(?:zelle\b|venmo\b|cash\s*app\b|money\s+transfer\b|online\s+transfer\b|transfer\s+(?:to|from)\b|payment\s+to\b)|paypal\s*\*\s*[a-z]+\.[a-z]+/i
    # A store seen in only one month is a one-off, not a monthly habit.
    MIN_MONTHS_FOR_A_CUT = 2
    # Services people pay for every month. With the bank's own "Recurring Payment" marker, these may change
    # price or skip a statement and still read as a subscription.
    KNOWN_SERVICE = /\b(?:netflix|hulu|disney|youtube|spotify|apple\.com|icloud|apple\s+(?:music|tv|one)|google\s+(?:one|workspace|storage)|amazon\s+prime|prime\s+video|audible|peacock|paramount|hbo|starlink|chatgpt|zoom|adobe|microsoft\s+365|dropbox|xbox|playstation|nintendo|crunchyroll)/i
    BANK_RECURRING = /\Arecurring\s+payment\b/i

    def self.protected_category?(name) = name.to_s.match?(PROTECTED_CATEGORY)

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
      last = dates.select { |date| date <= @today }.max
      finish = @to ? Date.iso8601(@to.to_s) : [ (last || @today.prev_month).end_of_month, @today ].min
      start = @from ? Date.iso8601(@from.to_s) : finish.beginning_of_month - 2.months
      raise ArgumentError, "Choose a past spending window of up to one year" unless start <= finish && finish <= @today && (finish - start).to_i <= 366
      selected_source = source.select { |row| row.posted_on&.between?(start, finish) }
      selected_actuals = actuals_scope.where(occurred_on: start..finish)
        .includes(transaction_splits: :budget_category).to_a
      # Budget counts a reviewed statement purchase only once it has a category; Mia counts the same lines.
      counted = selected_source.select { |row| eligible_ids.include?(row.id) && row.budget_category_id.present? }
      rows = counted.map { |row| source_row(row) } + selected_actuals.map { |row| actual_row(row) }
      # The same refund credits Budget uses: money back to the refunded purchase's categories, in the month the refund posted.
      credits = HouseholdFinance::RefundCredits.new(@household, from: start, to: finish).counted
      refund_categories = @household.budget_categories.where(id: credits.flat_map { |credit| credit.allocations.pluck(:category_id) }.uniq).index_by(&:id)
      rows += credits.map { |credit| refund_row(credit, refund_categories) }
      rows.each do |row|
        # Check the bank's own wording and the cleaned label, so "Purchase: Venmo to …" is still money sent to a person.
        row[:transfer_to_person] = [ row[:merchant].to_s, row[:merchant].to_s.sub(MerchantName::BANK_PREFIX, "") ].any? { |text| text.match?(PERSON_TRANSFER) }
        row[:bank_recurring] = row[:merchant].to_s.match?(BANK_RECURRING)
        row[:merchant] = MerchantName.call(row[:merchant])
      end
      rows.reject! { |row| row[:amount_cents].zero? }
      purchases = rows.reject { |row| row[:refund] }
      # All source classifications inform observed coverage; income-only months
      # are not represented as months with no spending. A month can net below zero
      # after a refund; that is shown as it is, never clamped.
      months = (start.beginning_of_month..finish).select { |day| day.day == 1 }.map do |month|
        in_month = rows.select { |row| row[:date].beginning_of_month == month }
        { month: month.strftime("%Y-%m"), purchase_count: in_month.count { |row| !row[:refund] }, spending_cents: in_month.any? ? in_month.sum { |row| row[:amount_cents] } : nil }
      end
      # A store or category refunded down to nothing (or below) is not somewhere she is spending.
      merchants = group_totals(rows, :merchant).select { |row| row[:total_cents].positive? }
      discretionary = rows.flat_map { |row| row[:splits].select { |split| split[:discretionary] && split[:amount_cents].nonzero? }.map { |split| row.merge(amount_cents: split[:amount_cents], category: split[:name], category_id: split[:category_id]) } }
      flexible_merchants = group_totals(discretionary, :merchant).select { |row| row[:total_cents].positive? }
      categories = group_totals(discretionary, :category).select { |row| row[:total_cents].positive? }
      cuttable = flexible_merchants.select { |row| row[:observed_months].length >= MIN_MONTHS_FOR_A_CUT && !row[:transfer_to_person] }
      choices = cuttable.first(3).map.with_index do |row, index|
        { id: "choice-#{index + 1}", label: "Cut back on #{row[:label]}", merchant: row[:label],
          monthly_impact_cents: (row[:monthly_average_cents] / 2.0).floor,
          description: "Try spending half as much at #{row[:label]}", assumption: "Half of the average in months with recorded purchases; an estimate, not saved money" }
      end.select { |row| row[:monthly_impact_cents].positive? }
      choices = [] unless months.any? { |row| row[:spending_cents] && row[:month] < @today.strftime("%Y-%m") }
      { window: { start_on: start.iso8601, end_on: finish.iso8601 },
        coverage: { status: "partial", months: months, accounts: selected_source.map { |row| row.source_tracked_account.label }.uniq.sort,
          account_completeness: "unknown", note: "Only confirmed purchases and reviewed statement rows are included. Approved refunds are subtracted from the category of the purchase they refund, in the month they posted; missing months, accounts and unreviewed uploads may change these patterns." },
        purchase_count: purchases.length, observed_spending_cents: rows.any? ? rows.sum { |row| row[:amount_cents] } : nil,
        merchants: merchants, discretionary_merchants: flexible_merchants, discretionary_categories: categories,
        small_purchase_clusters: clusters(purchases), possible_subscriptions: recurring(purchases), candidate_changes: choices,
        savings_inferred: false }
    end

    private

    def source_row(row)
      { source_version_id: row.id, kind: row.event_type, date: row.posted_on, merchant: FinancialDocuments::MerchantNormalizer.call(row.merchant.presence || "Unnamed purchase"), amount_cents: row.purchase_amount_cents || -row.signed_amount_cents,
        splits: [ split(row.budget_category, row.purchase_amount_cents || -row.signed_amount_cents) ] }
    end

    def actual_row(row)
      { date: row.occurred_on, merchant: FinancialDocuments::MerchantNormalizer.call(row.merchant), amount_cents: row.total_amount_cents,
        splits: row.transaction_splits.map { |value| split(value.budget_category, value.amount_cents) } }
    end

    # Money back, never a purchase: it nets the store and categories it came back to.
    def refund_row(credit, categories)
      { refund: true, date: credit.posted_on, merchant: FinancialDocuments::MerchantNormalizer.call(credit.original&.dig(:merchant).presence || credit.merchant.presence || "Unnamed purchase"),
        amount_cents: -credit.amount_cents, splits: credit.allocations.map { |part| split(categories[part[:category_id]], -part[:amount_cents]) } }
    end

    def split(category, amount)
      { category_id: category&.id, name: category&.name || "Uncategorized", amount_cents: amount,
        discretionary: category&.stack_key == "discretionary" && !self.class.protected_category?(category&.name) }
    end

    def group_totals(rows, key)
      rows.group_by { |row| row[key].to_s.unicode_normalize(:nfkc).squish.downcase }.map do |_, group|
        bought = group.reject { |row| row[:refund] }
        months = (bought.presence || group).map { |row| row[:date].strftime("%Y-%m") }.uniq
        total = group.sum { |row| row[:amount_cents] }
        { label: (bought.first || group.first)[key], total_cents: total, purchase_count: bought.length,
          observed_months: months.sort, monthly_average_cents: total.div(months.length),
          transfer_to_person: group.any? { |row| row[:transfer_to_person] } }
      end.sort_by { |row| [ -row[:total_cents], row[:label] ] }
    end

    def autopay_protected?(name) = self.class.protected_category?(name) || name.to_s.match?(/\b(?:insurance|premiums?|takecare|loan|mortgage|tuition)\b/i)

    def bank_charge?(row)
      return row[:kind].in?(%w[fee interest]) if row[:kind].present?

      row[:merchant].match?(/\A(?:nsf(?: (?:fee|charge))?|monthly service (?:fee|charge)|foreign[- ]transaction (?:fee|charge)|interest charge|(?:bank|service|overdraft|maintenance|atm|late) (?:service )?(?:fee|charge))\z/i)
    end

    def clusters(rows)
      small = rows.select { |row| row[:amount_cents] <= 2_500 && !bank_charge?(row) }
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
        # subscription wording, a participant-labelled subscription category,
        # a known monthly service or the bank's own recurring marker.
        subscription_label = group.first[:merchant].match?(/\b(?:subscriptions?|membership|stream(?:ing)?\s+service|netflix|spotify|gym|software|phone\s+plan|internet\s+plan)\b/i) ||
          group.any? { |row| row[:splits].any? { |split| split[:name].match?(/\b(?:subscriptions?|memberships?|streaming|software|gym|phone\s+plan|internet\s+plan)\b/i) } }
        known = group.first[:merchant].match?(KNOWN_SERVICE)
        bank_marked = group.any? { |row| row[:bank_recurring] }
        # The bank marks every autopay recurring, daycare and insurance included. Those are
        # protected costs, never a subscription to reconsider.
        bank_marked = false if group.any? { |row| row[:splits].any? { |split| autopay_protected?(split[:name]) } || autopay_protected?(row[:merchant]) }
        marked = known || bank_marked
        next unless subscription_label || marked
        dated = group.sort_by { |row| row[:date] }
        amounts = group.map { |row| row[:amount_cents] }.sort
        median = amounts[amounts.length / 2]
        steady = if marked
          # A price rise or one missed statement still reads as the same plan, but at least one
          # month-to-month charge must show it is monthly (two games two months apart are not).
          gaps = dated.each_cons(2).map { |first, second| (second[:date] - first[:date]).to_i }
          amounts.all? { |amount| (amount - median).abs <= [ 25, median * 15 / 100 ].max } &&
            gaps.any? { |gap| (26..35).cover?(gap) } && gaps.all? { |gap| (26..35).cover?(gap) || (bank_marked && (54..70).cover?(gap)) }
        else
          group.length >= 3 && dated.map { |row| row[:date].strftime("%Y-%m") }.uniq.length >= 3 &&
            amounts.all? { |amount| (amount - median).abs <= [ 25, median / 100 ].max } &&
            dated.each_cons(2).all? { |first, second| (26..35).cover?((second[:date] - first[:date]).to_i) }
        end
        next unless steady
        { merchant: group.first[:merchant], typical_amount_cents: median, latest_amount_cents: dated.last[:amount_cents],
          last_charged_on: dated.last[:date].iso8601, observed_payments: group.length, confirmed_subscription: false }
      end.sort_by { |row| [ -row[:latest_amount_cents], row[:merchant] ] }
    end
  end
end
