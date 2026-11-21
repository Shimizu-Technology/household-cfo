module SpendingPatterns
  # Observations, never an assertion of complete account coverage or affordability.
  # Read approved source heads directly and exclude their projected transactions,
  # so a statement purchase cannot appear twice.
  class Analyzer
    # The Household CFO Method never suggests cutting the roof, utilities, medical care, children or family
    # (Mrs. Mel: "I would never tell someone… don't take care of your family"). These stay in spending totals
    # but are not flexible spending and are never offered as a cut.
    # "Family support", "child support", "support for Nana": money for family. Not "Tech support", nor a reply's
    # "to support your savings goal".
    FAMILY_SUPPORT = /(?:family|child|spousal|parent(?:al)?)\s+support|support\s+(?:for|to)\s+(?:my\s+|our\s+|the\s+)?(?:family|kids?|child(?:ren)?|parents?|mom|dad|lola|lolo|nana|tata|auntie|aunt|uncle|relatives?|grand(?:ma|pa|parents?))/i
    # "Health and beauty" or "Health & fitness" is shopping, not care.
    NOT_HEALTH_CARE = /\s*(?:and|&|\+)\s*(?:beauty|fitness)\b/i
    # Category words for each protected category a program can choose (CohortExperience::MethodSettings).
    PROTECTED_CATEGORY_WORDS = {
      "housing" => /\b(?:rent|mortgage|housing)\b/i,
      "utilities" => /\b(?:utilities|utility|power|water|electric(?:ity)?)\b/i,
      "medical" => /\b(?:medical|medicine|medications?|meds|doctors?|dental|dentist|health(?!#{NOT_HEALTH_CARE})|healthcare|pharmacy|prescriptions?|hospital|clinic|therapy|prenatal|pediatrics?|optical)\b/i,
      "childcare_school" => /\b(?:child(?:ren)?|childcare|daycare|preschool|nann(?:y|ies)|after\s*-?\s*school|babysit(?:ter|ting)?|kids?|baby|babies|diapers?|school|tuition|daughters?|sons?)\b/i,
      "family_support" => /\b(?:family|mom|mother|dad|father|parents?|grandparents?|grand(?:ma|pa)|lola|lolo|nana|auntie|aunt|uncle|relatives?|#{FAMILY_SUPPORT}|remittances?)\b/i,
      # Bills, not a store habit. Kept apart from the care words because "cut your debt" is good advice.
      "debt_minimums" => /\b(?:loans?|debts?|(?:car|card|credit\s+card)\s+payments?)\b/i,
      # Only when the program adds them.
      "groceries" => /\b(?:groceries|grocery|supermarkets?|food\s+at\s+home)\b/i,
      "giving" => /\b(?:giving|tith(?:e|es|ing)|donations?|offerings?|charit(?:y|able)|church)\b/i,
      "community" => /\b(?:community|fiestas?|novenas?|funerals?|rosary|rosaries)\b/i
    }.freeze
    CORE_PROTECTED = CohortExperience::MethodSettings::CORE_PROTECTED
    PROTECTED_CATEGORY = Regexp.union(PROTECTED_CATEGORY_WORDS.slice(*CORE_PROTECTED).except("debt_minimums").values)
    # Insurance is a contract bill whatever the program chooses, like the store names below.
    ALWAYS_PROTECTED_CATEGORY = /\b(?:insurance|premiums?)\b/i
    BILL_CATEGORY = Regexp.union(ALWAYS_PROTECTED_CATEGORY, PROTECTED_CATEGORY_WORDS.fetch("debt_minimums"))
    # A store name that is care or a bill, whatever category it was filed under: a clinic filed as
    # "Flexible spending" is still medical care. Narrower than the category words, so "Family Mart" or
    # "Mom's Kitchen" can still be a store.
    # A food or shop word right after a care word makes the name a store: "Dr Juice Bar", "Whole Health Foods",
    # "Vision Buffet". "Island Vision Center" and "Dr. Cruz" are still care.
    STORE_AFTER = /(?:\s+[\w'&-]+)?\s+(?:buffet|restaurant|grill|bar|cafe|café|coffee|tea|pizza|kitchen|bakery|burgers?|bbq|diner|deli|juice|smoothies?|boba|foods?|nutrition)\b/i
    # A plant nursery, not childcare: "Island Garden Nursery", "Nursery & Garden Center".
    PLANT_NURSERY = /(?<!garden\s|plant\s|plants\s|tree\s)nursery\b(?!(?:\s*(?:&|and)\s*|\s+)(?:garden|plants?|landscap\w*|trees?|greenhouse)\b)/i
    PROTECTED_MERCHANT = /
      \b(?:clinic|hospital|medical|health(?!#{STORE_AFTER}|#{NOT_HEALTH_CARE})|health\s*care|pharm\w*|drugs?(?:\s*store)?|walgreens|cvs|rite\s*-?\s*aid
        |dental|dentist|orthodont\w*|doctors?|physicians?|pediatric\w*|prenatal|ob\s*[-\/&]?\s*gyn|obstetric\w*|urgent\s+care
        |optometr\w*|optical|eye\s*care|vision(?!#{STORE_AFTER})|chiropract\w*|therapy|counsel(?:ing|ling|or)|laborator(?:y|ies)|labcorp
        |(?:diagnostic|clinical|medical|blood|imaging|x-?ray)\s+labs?
        |daycare|day\s+care|childcare|child\s+care|pre-?school|#{PLANT_NURSERY}|babysit\w*|nann(?:y|ies)|after\s*-?\s*school|montessori
        # "Rent-A-Center" rents out furniture; "Utility Trailer Sales" sells trailers.
        |insurance|assurance|takecare|loan|mortgage|rent\b(?!\s*-\s*a\s*-|\s+a\s+(?:center|car|wreck)\b)|apartments?|realty|property\s+management|power\s+authority|waterworks
        |utilit(?:y|ies)\b(?!\s+(?:trailers?|vehicles?|trucks?|carts?|sinks?|knife|knives)\b))\b
      # "Island Rx", "Rx Express", but not "Rx Pizza".
      |\brx(?:\s*\#?\s*\d+)?\z|\brx\s+(?:express|plus|care|center|centre|shop|mart|depot)\b
      # A doctor's name: "Dr. Cruz", "DR LEON GUERRERO"; never "Dr Pepper", "Dr. Martens" or "Dr Juice Bar".
      |(?:\A|\s)dr\.?(?!#{STORE_AFTER})\s+(?!pepper\b|martens?\b)[a-z]
      # "Ana Cruz MD", "Cruz, M.D.": the letters themselves, as a word after the name. Plain "MD" after a
      # store number is the bank's state code: "TARGET 1234 BALTIMORE MD".
      |(?-i:,\s*M\.?D\b\.?|\sM\.D\b\.?|\A[^\d\#]*\sMD\b)(?=\s|,|\z)
    /ix
    # Money sent to a person is usually support or paying someone back, not a store habit to halve.
    PERSON_TRANSFER = /\A(?:zelle\b|venmo\b|cash\s*app\b|money\s+transfer\b|online\s+transfer\b|transfer\s+(?:to|from)\b|payment\s+to\b)|paypal\s*\*\s*[a-z]+\.[a-z]+/i
    # Money sent home through a remittance service, or a line that says who it went to.
    REMITTANCE = /\b(?:western\s+union|money\s*gram|remitly|xoom|world\s*remit|transfer\s*wise|wise\s+(?:transfers?|payments?)|wise\.com|lbc|remit(?:tances?)?)\b|\bsent\s+to\b/i
    # A store seen in only one month is a one-off, not a monthly habit.
    MIN_MONTHS_FOR_A_CUT = 2
    # A payment this many times a store's usual one is a one-off there ($690 once at a store where
    # she usually spends $20). It is left out of the store's monthly figure.
    ONE_OFF_MULTIPLE = 3
    # Two months at a store count as a habit only when one is at most this many times the other.
    SIMILAR_MONTHS_MULTIPLE = 2
    # Services people pay for every month. With the bank's own "Recurring Payment" marker, these may change
    # price or skip a statement and still read as a subscription.
    KNOWN_SERVICE = /\b(?:netflix|hulu|disney|youtube|spotify|apple\.com|icloud|apple\s+(?:music|tv|one)|google\s+(?:one|workspace|storage)|amazon\s+prime|prime\s+video|audible|peacock|paramount|hbo|starlink|chatgpt|zoom|adobe|microsoft\s+365|dropbox|xbox|playstation|nintendo|crunchyroll)/i
    BANK_RECURRING = /\Arecurring\s+payment\b/i

    # protected: the program's protected categories. The core ones are always protected.
    def self.protected_category?(name, protected = CORE_PROTECTED)
      text = name.to_s
      text.match?(ALWAYS_PROTECTED_CATEGORY) || PROTECTED_CATEGORY_WORDS.slice(*(CORE_PROTECTED | Array(protected))).values.any? { |words| text.match?(words) }
    end
    UTILITY_COMPANY = /\b(?:power|electric(?:ity)?|water|gas(?=[,\s]+(?:co\b|company\b|corporation\b|corp\b|inc\b|llc\b|ltd\b|authority\b|services?\b|utilit(?:y|ies)\b|district\b|department\b|board\b))|sewer|telecom(?:munications)?|telephone|internet|broadband)\b(?:,?\s+(?:co\.?|company|corporation|corp\.?|inc\.?|llc|ltd\.?|authority|services?|utility|utilities|district|department|board))*\s*\z/i

    def self.protected_merchant?(name) = name.to_s.match?(PROTECTED_MERCHANT) || name.to_s.match?(UTILITY_COMPANY)

    # protected: the program's protected categories; nil reads the household's own program.
    def initialize(household, today: Time.current.in_time_zone("Pacific/Guam").to_date, from: nil, to: nil, protected: nil)
      @household, @today, @from, @to = household, today, from, to
      @protected = protected
    end

    def protected_categories
      @protected_categories ||= CORE_PROTECTED | Array(@protected || CohortExperience::MethodSettings.for_household(@household).fetch("protected"))
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
      rows = counted.map { |row| source_row(row).merge(transfer_to_person: row.external_reference.to_s.start_with?("sent-to-someone:")) } + selected_actuals.map { |row| actual_row(row) }
      # The same refund credits Budget uses: money back to the refunded purchase's categories, in the month the refund posted.
      credits = HouseholdFinance::RefundCredits.new(@household, from: start, to: finish).counted
      refund_categories = @household.budget_categories.where(id: credits.flat_map { |credit| credit.allocations.pluck(:category_id) }.uniq).index_by(&:id)
      rows += credits.map { |credit| refund_row(credit, refund_categories) }
      # Budget's cash rule: a purchase paid from cash she took out moves that cash out of the withdrawal's category into
      # its own, in the month the cash was withdrawn, and adds nothing in its own month.
      rows += cash_rows(HouseholdFinance::CashDrawdowns.new(@household).call, start, finish)
      rows.each do |row|
        # Check the bank's own wording and the cleaned label, so "Purchase: Venmo to …" is still money sent to a person.
        row[:transfer_to_person] ||= [ row[:merchant].to_s, row[:merchant].to_s.sub(MerchantName::BANK_PREFIX, "") ].any? { |text| text.match?(PERSON_TRANSFER) } || row[:merchant].to_s.match?(REMITTANCE)
        row[:bank_recurring] = row[:merchant].to_s.match?(BANK_RECURRING)
        row[:merchant] = MerchantName.call(row[:merchant])
      end
      rows.reject! { |row| row[:amount_cents].zero? }
      # Split rows below keep this, so a purchase split across categories is still one payment.
      rows.each_with_index { |row, index| row[:row_id] = index }
      purchases = rows.reject { |row| row[:refund] || row[:adjustment] }
      # All source classifications inform observed coverage; income-only months
      # are not represented as months with no spending. A month can net below zero
      # after a refund; that is shown as it is, never clamped.
      months = (start.beginning_of_month..finish).select { |day| day.day == 1 }.map do |month|
        in_month = rows.select { |row| row[:date].beginning_of_month == month }
        { month: month.strftime("%Y-%m"), purchase_count: in_month.count { |row| !row[:refund] && !row[:adjustment] }, spending_cents: in_month.any? ? in_month.sum { |row| row[:amount_cents] } : nil }
      end
      # A store or category refunded down to nothing (or below) is not somewhere she is spending.
      merchants = group_totals(rows, :merchant).select { |row| row[:total_cents].positive? }
      by_category = rows.flat_map { |row| row[:splits].select { |split| split[:amount_cents].nonzero? }.map { |split| row.merge(amount_cents: split[:amount_cents], category: split[:name], category_id: split[:category_id], discretionary: split[:discretionary]) } }
      all_categories = group_totals(by_category, :category).select { |row| row[:total_cents].positive? }
      # Care, bills and money sent to a person stay in the totals above but are never flexible spending,
      # whichever category they were filed under.
      discretionary = by_category.select { |row| row[:discretionary] && !row[:transfer_to_person] && !self.class.protected_merchant?(row[:merchant]) }
      flexible_merchants = group_totals(discretionary, :merchant).select { |row| row[:total_cents].positive? }
      categories = group_totals(discretionary, :category).select { |row| row[:total_cents].positive? }
      # Only a store she keeps going back to, without its one-off payments, can be a monthly cut.
      cuttable = flexible_merchants.select { |row| row[:monthly_habit] && row[:monthly_average_cents].positive? }
      choices = cuttable.first(3).map.with_index do |row, index|
        { id: "choice-#{index + 1}", label: "Cut back on #{row[:label]}", merchant: row[:label],
          monthly_impact_cents: (row[:monthly_average_cents] / 2.0).floor,
          description: "Try spending half as much at #{row[:label]}", assumption: "Half of the average in months with recorded purchases there, leaving out one-off payments; an estimate, not saved money" }
      end.select { |row| row[:monthly_impact_cents].positive? }
      choices = [] unless months.any? { |row| row[:spending_cents] && row[:month] < @today.strftime("%Y-%m") }
      { window: { start_on: start.iso8601, end_on: finish.iso8601 },
        coverage: { status: "partial", months: months, accounts: selected_source.map { |row| row.source_tracked_account.label }.uniq.sort,
          account_completeness: "unknown", note: "Only confirmed purchases and reviewed statement rows are included. Approved refunds are subtracted from the category of the purchase they refund, in the month they posted. A purchase paid from cash she took out counts in the month the cash was withdrawn, out of that withdrawal's category; missing months, accounts and unreviewed uploads may change these patterns." },
        purchase_count: purchases.length, observed_spending_cents: rows.any? ? rows.sum { |row| row[:amount_cents] } : nil,
        merchants: merchants, categories: all_categories, discretionary_merchants: flexible_merchants, recurring_discretionary_merchants: cuttable,
        discretionary_categories: categories,
        small_purchase_clusters: clusters(purchases), possible_subscriptions: recurring(purchases), candidate_changes: choices,
        protected_categories: protected_categories, savings_inferred: false }
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

    # Moves, never purchases: the linked part of a cash purchase leaves its own month and the withdrawal's category, and
    # lands in the purchase's categories in the month the cash was taken out.
    def cash_rows(drawdowns, start, finish)
      ids = drawdowns.flat_map { |drawdown| (drawdown.cash_parts + drawdown.purchase_parts).pluck(:category_id) }.uniq
      categories = ids.any? ? @household.budget_categories.where(id: ids).index_by(&:id) : {}
      parts = ->(list, sign) { list.map { |part| split(categories[part[:category_id]], sign * part[:amount_cents]) } }
      drawdowns.flat_map do |drawdown|
        purchase = FinancialDocuments::MerchantNormalizer.call(drawdown.purchase.merchant)
        rows = []
        if drawdown.withdrawn_on.between?(start, finish)
          rows << { adjustment: true, date: drawdown.withdrawn_on, merchant: purchase, amount_cents: drawdown.amount_cents, splits: parts.call(drawdown.purchase_parts, 1) }
          rows << { adjustment: true, date: drawdown.withdrawn_on, merchant: FinancialDocuments::MerchantNormalizer.call(drawdown.withdrawal.merchant),
            amount_cents: -drawdown.amount_cents, splits: parts.call(drawdown.cash_parts, -1) }
        end
        if drawdown.purchased_on.between?(start, finish)
          rows << { adjustment: true, date: drawdown.purchased_on, merchant: purchase, amount_cents: -drawdown.amount_cents, splits: parts.call(drawdown.purchase_parts, -1) }
        end
        rows
      end
    end

    def split(category, amount)
      { category_id: category&.id, name: category&.name || "Uncategorized", amount_cents: amount,
        discretionary: category&.stack_key == "discretionary" && !self.class.protected_category?(category&.name, protected_categories) }
    end

    def group_totals(rows, key)
      rows.group_by { |row| row[key].to_s.unicode_normalize(:nfkc).squish.downcase }.map do |_, group|
        # One payment per purchase, however many categories it was split across.
        bought = group.reject { |row| row[:refund] || row[:adjustment] }.group_by { |row| row[:row_id] }
          .map { |_, parts| parts.first.merge(amount_cents: parts.sum { |part| part[:amount_cents] }) }
        months = (bought.presence || group).map { |row| row[:date].strftime("%Y-%m") }.uniq
        total = group.sum { |row| row[:amount_cents] }
        one_offs = one_off_payments(bought)
        regular = bought - one_offs
        regular_months = regular.map { |row| row[:date].strftime("%Y-%m") }.uniq
        # Money back goes to the one-off first (the crib she returned), so it never pulls her usual
        # visits below zero; only what is left over comes off the regular months.
        refunds = group.select { |row| row[:refund] }.sum { |row| row[:amount_cents] }
        regular_total = regular.sum { |row| row[:amount_cents] } + [ refunds + one_offs.sum { |row| row[:amount_cents] }, 0 ].min
        { label: (bought.first || group.first)[key], total_cents: total, purchase_count: bought.length,
          observed_months: months.sort, regular_months: regular_months.sort, monthly_habit: monthly_habit?(regular),
          monthly_average_cents: regular_months.any? ? regular_total.div(regular_months.length) : 0,
          transfer_to_person: group.any? { |row| row[:transfer_to_person] } }
      end.sort_by { |row| [ -row[:total_cents], row[:label] ] }
    end

    # Payments far above the others at that store: $690 once where she usually spends $20. Each is set
    # against the middle of the rest, so one large payment can't raise the bar for itself.
    def one_off_payments(bought)
      return [] if bought.length < 2

      sorted = bought.map { |row| row[:amount_cents] }.sort
      rest_length = sorted.length - 1
      bought.select do |row|
        # The middle of the others, read from one sorted list with this payment skipped.
        skipped = sorted.bsearch_index { |amount| amount >= row[:amount_cents] }
        rest = ->(position) { sorted[position < skipped ? position : position + 1] }
        middle = rest_length.odd? ? rest.call(rest_length / 2) : (rest.call(rest_length / 2 - 1) + rest.call(rest_length / 2)) / 2.0
        row[:amount_cents] > middle * ONE_OFF_MULTIPLE
      end
    end

    # Somewhere she keeps going back to: at least two months, and either three visits or two months of
    # about the same size. $250 in September and $690 in October could be two one-offs, so neither
    # becomes "a month".
    def monthly_habit?(regular)
      by_month = regular.group_by { |row| row[:date].strftime("%Y-%m") }.transform_values { |group| group.sum { |row| row[:amount_cents] } }
      return false if by_month.length < MIN_MONTHS_FOR_A_CUT
      return true if regular.length >= 3

      low, high = by_month.values.minmax
      low.positive? && high <= low * SIMILAR_MONTHS_MULTIPLE
    end

    def autopay_protected?(name) = self.class.protected_category?(name) || self.class.protected_merchant?(name) || name.to_s.match?(/\b(?:insurance|premiums?|takecare|loan|mortgage|tuition)\b/i)

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
