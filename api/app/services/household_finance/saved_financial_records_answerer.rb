# frozen_string_literal: true

module HouseholdFinance
  # Explicit inventory questions are answered from approved records without a
  # provider, draft, or annual-plan creation. Advice and ambiguous scope remain
  # with the appropriate household/challenge coaching route.
  class SavedFinancialRecordsAnswerer
    Result = Struct.new(:answer, :metadata, keyword_init: true)
    MAX_RECORDS = 20
    MAX_SCHEDULE_ENTRIES = 6
    TOPICS = {
      income: /\b(?:income|pay|salary)(?:\s+sources?)?\b/i,
      debts: /\b(?:debts?|credit cards?)\b/i,
      accounts: /\b(?:accounts?|assets?)\b/i,
      goals: /\b(?:goals?)\b/i
    }.freeze
    READ_PREFIX = /\A(?:please\s+)?(?:list\b|show\b|tell me\b|what\b|which\b|where (?:does|is)\b|how much\b)/i.freeze
    MUTATION = /\b(?:set|change|update|increase|decrease|lower|raise|move|create|add|rename|archive|restore|schedule|end|stop|delete|remove|link|unlink|reconcile|apply|cancel)\b/i.freeze
    OTHER_SCOPE = /\b(?:statements?|uploads?|uploaded|documents?|receipts?|challenge|cohort|bog|90[ -]day|reserved|set aside|withdrawals?|refunds?|baseline|transactions?|purchases?|afford|should|recommend|prioriti[sz]e|hypothetical|scenario|if|could|would|might)\b/i.freeze

    def initialize(household, message:, year:, month:)
      @household, @message = household, message.to_s.squish
      @reference_date = Date.new(Integer(year), Integer(month), 1)
    end

    def call
      text = @message.sub(/(?:[.!]\s*|\s+)(?:please\s+)?(?:do not|don't|without)\s+(?:change|update|edit|save|apply)(?:\s+anything|\s+any(?:\s+records)?|\s+records|\s+it)?[.!]?\z/i, "")
      return unless text.match?(READ_PREFIX)
      return unless text.match?(/\b(?:my|our|saved|household)\b/i)
      return if text.match?(MUTATION) || text.match?(OTHER_SCOPE)
      return if text.match?(/\b(?:saved|savings)\s+progress\b|\bsavings\s+(?:goal|target)\b/i)
      topics = TOPICS.filter_map { |topic, pattern| topic if text.match?(pattern) }
      return unless topics.one?
      # Exclude recommendations framed as questions even when a topic matches.
      return if text.match?(/\b(?:best|better|strategy|pay off|pay first|can i|can we|will i|will we)\b/i)

      reference = requested_reference_date(text)
      return if reference == false
      @reference_date = reference || @reference_date
      send("answer_#{topics.sole}")
    end

    private

    def requested_reference_date(text)
      relative = text.scan(/\b(?:this|current|next|last)\s+month\b/i).uniq
      month_names = Date::MONTHNAMES.compact + Date::ABBR_MONTHNAMES.compact
      named = text.scan(/\b(?:#{month_names.join('|')})\b/i).map { |name| Date::ABBR_MONTHNAMES.index { |item| item&.casecmp?(name.first(3)) } }.uniq
      years = text.scan(/\b(?:20\d{2}|2100)\b/).map(&:to_i).uniq
      return false if relative.length > 1 || named.length > 1 || years.length > 1 || (relative.any? && (named.any? || years.any?))
      if relative.any?
        return Date.current.beginning_of_month.next_month if relative.sole.match?(/next/i)
        return Date.current.beginning_of_month.prev_month if relative.sole.match?(/last/i)
        return Date.current.beginning_of_month
      end
      return if named.empty? && years.empty?
      Date.new(years.first || @reference_date.year, named.first || @reference_date.month, 1)
    end

    def answer_income
      inventory = SavedIncomeInventory.new(@household, on: @reference_date, record_limit: MAX_RECORDS, schedule_limit: MAX_SCHEDULE_ENTRIES).call
      if inventory[:total_count].zero?
        return result(:income, "No income sources are saved in your household plan yet. Your income is unknown from these records; this does not mean $0. Add your sources in My Money → Income or ask Mia to draft one.", inventory)
      end
      lines = [ "Saved household income for #{month_label}: #{money(inventory[:selected_month_amount])} in the monthly plan, including one-time scheduled income. Recurring monthly equivalent: #{money(inventory[:recurring_monthly_amount])}." ]
      lines << coverage_sentence(inventory[:total_count], inventory[:shown_count])
      inventory[:records].each do |source|
        effective = source[:effective_amount].nil? ? "not effective in this month" : "effective #{money(source[:effective_amount])} #{cadence(source[:effective_cadence])}"
        line = "#{label(source[:label])} (#{source[:source_type].humanize}): base #{money(source[:base_amount])} #{cadence(source[:base_cadence])}; #{effective}; #{money(source[:selected_month_amount])} in #{month_label}. Status: #{source[:timeline_status]}."
        line += " Starts #{source[:starts_on]}." if source[:starts_on]
        line += " Ends before #{source[:ends_on]} (that month is excluded)." if source[:ends_on]
        lines << line
        source[:schedule_entries].each do |entry|
          kind = entry[:entry_type] == "one_time" ? "one-time" : "recurring change"
          lines << "  #{entry[:effective_on]}: #{kind}#{entry[:label].present? ? " — #{label(entry[:label])}" : ''}, #{money(entry[:amount])} #{cadence(entry[:cadence])}#{entry[:active] ? '.' : '; outside the source timeline, excluded.'}"
        end
        if source[:upcoming_schedule_count] > source[:schedule_entries].length
          lines << "  Showing #{source[:schedule_entries].length} of #{source[:upcoming_schedule_count]} current and future entries. Open Income for the rest."
        end
      end
      lines << inventory[:completeness_note]
      result(:income, lines.join("\n"), inventory)
    end

    def answer_debts
      profile = @household.household_profile
      if profile&.debt_tracking_mode == "summary"
        answer = "Your household plan uses summary debt tracking: balance #{known_money(profile.debt_summary_balance_known?, profile.debt_summary_balance_cents)}, monthly minimum #{known_money(profile.debt_summary_minimum_payment_known?, profile.debt_summary_minimum_payment_cents)}. Individual records are preserved but excluded from that total. This is separate from the challenge's optional card-term review and does not establish complete debt coverage."
        return result(:debts, answer, tracking_mode: "summary")
      end
      scope = @household.debts.active.order(:debt_type, :label, :id)
      rows = scope.limit(MAX_RECORDS).map do |debt|
        "#{label(debt.label)} (#{debt.debt_type.humanize}): balance #{known_money(debt.balance_known?, debt.balance_cents)}, monthly minimum #{known_money(debt.minimum_payment_known?, debt.minimum_payment_cents)}, APR #{debt.interest_rate_percent.nil? ? 'unknown' : "#{debt.interest_rate_percent.to_s('F')}%"}."
      end
      inventory_result(:debts, scope.count, rows, "These are saved household debts, separate from the challenge's optional card-term review. Missing values remain unknown; the list does not establish complete debt coverage or lender payoff amounts.")
    end

    def answer_accounts
      scope = @household.accounts.active.order(:account_type, :label, :id)
      rows = scope.limit(MAX_RECORDS).map do |account|
        "#{label(account.label)} (#{account.account_type.humanize}): balance #{known_money(account.balance_known?, account.balance_cents)}#{account.balance_as_of_on ? " as of #{account.balance_as_of_on.iso8601}" : ', balance date unknown'}."
      end
      inventory_result(:accounts, scope.count, rows, "Balances are approved household snapshots, not verified live bank balances. Account savings balances do not automatically count toward challenge savings.")
    end

    def answer_goals
      scope = @household.goals.tracked.active.order(:priority, :id)
      rows = scope.limit(MAX_RECORDS).map do |goal|
        "#{label(goal.label)} (#{goal.goal_type.humanize}): target #{known_money(goal.target_amount_known?, goal.target_amount_cents)}, recorded progress #{known_money(goal.current_amount_known?, goal.current_amount_cents)}, target date #{goal.target_on&.iso8601 || 'unknown'}."
      end
      inventory_result(:goals, scope.count, rows, "These are household tracked goals. They do not move money or change the challenge's accepted savings target, reserved money, or reported progress.")
    end

    def inventory_result(topic, total, rows, note)
      lead = total.zero? ? "No active #{topic} are saved in your household plan. This does not establish zero balances or complete coverage." : "Saved household #{topic}: #{coverage_sentence(total, rows.length)}"
      result(topic, ([ lead ] + rows + [ note ]).join("\n"), total_count: total, shown_count: rows.length, coverage: total > rows.length ? "bounded_saved_records" : "all_saved_records")
    end

    def result(topic, answer, metadata = {})
      Result.new(answer: answer, metadata: metadata.merge(kind: "saved_financial_records", topic: topic.to_s, scope: "saved_household", reference_month: @reference_date.iso8601, write_state: "no_write"))
    end

    def coverage_sentence(total, shown)
      total > shown ? "Showing #{shown} of #{total} saved records; open My Money for the rest. Totals include all saved sources." : "Showing all #{total} saved #{'record'.pluralize(total)}."
    end

    def label(value) = value.to_s.gsub(/[[:cntrl:]]/, " ").squish
    def month_label = @reference_date.strftime("%B %Y")
    def cadence(value) = { "weekly" => "per week", "biweekly" => "every two weeks", "semi_monthly" => "twice a month", "monthly" => "per month", "annual" => "per year", "one_time" => "one time" }.fetch(value, value.to_s)
    def known_money(known, cents) = known ? money(Money.dollars(cents)) : "unknown"
    def money(dollars) = ActiveSupport::NumberHelper.number_to_currency(dollars, precision: 2)
  end
end
