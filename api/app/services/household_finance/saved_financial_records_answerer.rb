# frozen_string_literal: true

module HouseholdFinance
  # Explicit inventory questions are answered from approved records without a
  # provider, draft, or annual-plan creation. Advice and ambiguous scope remain
  # with the appropriate household/challenge coaching route.
  class SavedFinancialRecordsAnswerer
    Result = Struct.new(:answer, :metadata, keyword_init: true)
    attr_reader :decline_reason
    MAX_RECORDS = 20
    MAX_SCHEDULE_ENTRIES = 6
    TOPICS = {
      income: /\b(?:income|pay|salary)(?:\s+sources?)?\b/i,
      debts: /\b(?:debts?|credit cards?)\b/i,
      accounts: /\b(?:accounts?|assets?)\b/i,
      goals: /\b(?:goals?)\b/i,
      spending: /\b(?:spending|budget|planned amounts?|categor(?:y|ies)|expense stacks?)\b/i
    }.freeze
    READ_PREFIX = /\A(?:please\s+)?(?:list\b|show\b|tell me\b|what\b|which\b|where (?:does|is)\b|how much\b)/i.freeze
    MUTATION = /\b(?:set|change|update|adjust|make|increase|decrease|lower|raise|reduce|move|transfer|shift|create|add|edit|rename|reclassify|recategorize|archive|restore|schedule|end|stop|delete|remove|link|unlink|reconcile|apply|cancel)\b/i.freeze
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
      # Ranking and analysis retain the established budget answerer and its
      # conversation references; this reader is an inventory/record lookup.
      return if text.match?(/\b(?:largest|biggest|highest|smallest|lowest|top|compare|comparison|on track|over budget|under budget)\b/i)
      return if text.match?(/\b(?:annual|yearly|(?:this|current|next|last)\s+year|all year)\b/i)

      reference = requested_reference_date(text)
      if reference == false
        @decline_reason = :ambiguous_period
        return
      end
      @reference_date = reference || @reference_date
      @read_text = text
      send("answer_#{topics.sole}")
    end

    private

    def requested_reference_date(text)
      # Numeric dates must not collapse to their year and silently use the
      # currently selected month. Unsupported formats belong to clarification.
      return false if text.match?(/\b\d{1,4}\/\d{1,4}(?:\/\d{1,4})?\b/)
      numeric = text.scan(/\b\d{4}[-–—][^\s,.!?;:)\]"']*/).uniq
      return false if numeric.length > 1
      numeric_date = nil
      if numeric.any?
        token = numeric.sole
        return false unless token.match?(/\A\d{4}-\d{2}(?:-\d{2})?\z/)
        numeric_date = Date.iso8601(token.length == 7 ? "#{token}-01" : token).beginning_of_month
        return false unless numeric_date.year.between?(2000, 2100)
      end
      relative = text.scan(/\b(?:(?:this|current|next|last)\s+month|today|now)\b/i).map(&:downcase).uniq
      month_names = Date::MONTHNAMES.compact + Date::ABBR_MONTHNAMES.compact
      named = text.scan(/\b(?:#{month_names.join('|')})\b/i).map { |name| Date::ABBR_MONTHNAMES.index { |item| item&.casecmp?(name.first(3)) } }.uniq
      years = text.scan(/\b(?:20\d{2}|2100)\b/).map(&:to_i).uniq
      return false if relative.length > 1 || named.length > 1 || years.length > 1 || (relative.any? && (named.any? || years.any?))
      if numeric_date
        return false if relative.any? || (named.any? && named.sole != numeric_date.month) || (years.any? && years.sole != numeric_date.year)
        return numeric_date
      end
      if relative.any?
        return Date.current.beginning_of_month.next_month if relative.sole.match?(/next/i)
        return Date.current.beginning_of_month.prev_month if relative.sole.match?(/last/i)
        return Date.current.beginning_of_month
      end
      return if named.empty? && years.empty?
      Date.new(years.first || @reference_date.year, named.first || @reference_date.month, 1)
    rescue Date::Error
      false
    end

    def answer_income
      inventory = SavedIncomeInventory.new(@household, on: @reference_date, record_limit: MAX_RECORDS, schedule_limit: MAX_SCHEDULE_ENTRIES).call
      if inventory[:total_count].zero?
        return result(:income, "No income sources are saved in your household plan yet. Your income is unknown from these records; this does not mean $0. Add your sources in My Money → Income or ask Mia to draft one.", inventory)
      end
      records = []
      blocks = []
      inventory[:records].each do |source|
        block = income_source_block(source)
        proposed = income_answer_text(inventory, blocks + [ block ], records.length + 1)
        break if proposed.length > ChatMessage::MAX_ASSISTANT_CONTENT_LENGTH
        records << source
        blocks << block
      end
      inventory[:records] = records
      inventory[:shown_count] = records.length
      inventory[:coverage] = inventory[:total_count] > records.length ? "bounded_saved_records" : "all_saved_records"
      result(:income, income_answer_text(inventory, blocks, records.length), inventory)
    end

    def income_answer_text(inventory, blocks, shown)
      lines = [ "Saved household income for #{month_label}: #{money(inventory[:selected_month_amount])} in the monthly plan, including one-time scheduled income. Recurring monthly equivalent: #{money(inventory[:recurring_monthly_amount])}.",
        coverage_sentence(inventory[:total_count], shown) ]
      lines << "Monthly totals include all saved sources, including sources omitted below." if inventory[:total_count] > shown
      (lines + blocks + [ inventory[:completeness_note] ]).join("\n\n")
    end

    def income_source_block(source)
      effective = source[:effective_amount].nil? ? "not effective in this month" : "effective #{money(source[:effective_amount])} #{cadence(source[:effective_cadence])}"
      line = "#{label(source[:label])} (#{source[:source_type].humanize}): base #{money(source[:base_amount])} #{cadence(source[:base_cadence])}; #{effective}; #{money(source[:selected_month_amount])} in #{month_label}. Status: #{source[:timeline_status]}."
      line += " Starts #{source[:starts_on]}." if source[:starts_on]
      line += " Ends before #{source[:ends_on]} (that month is excluded)." if source[:ends_on]
      lines = [ line ]
      source[:schedule_entries].each do |entry|
        kind = entry[:entry_type] == "one_time" ? "one-time" : "recurring change"
        lines << "  #{entry[:effective_on]}: #{kind}#{entry[:label].present? ? " — #{label(entry[:label])}" : ''}, #{money(entry[:amount])} #{cadence(entry[:cadence])}#{entry[:active] ? '.' : '; outside the source timeline, excluded.'}"
      end
      if source[:upcoming_schedule_count] > source[:schedule_entries].length
        lines << "  Showing #{source[:schedule_entries].length} of #{source[:upcoming_schedule_count]} current and future entries. Open Income for the rest."
      end
      lines.join("\n\n")
    end

    def answer_spending
      plan = AnnualBudgetManager.new(@household, year: @reference_date.year).read_only_plan_data
      rows = plan.fetch(:rows)
      matches = @read_text.match?(/\b(?:categories|expense stacks?|by category)\b/i) ? [] : spending_category_matches(rows)
      if matches.length > 1
        names = matches.first(10).map { |row| "#{label(row[:name])} (#{row[:stack_label]})" }
        qualification = matches.length > names.length ? " Showing #{names.length} of #{matches.length} matching names." : ""
        return result(:spending, "More than one household spending category matches that request: #{names.join(', ')}.#{qualification} Name one exact category or ask for all spending categories. No records changed.", total_count: matches.length, shown_count: names.length, coverage: "ambiguous_category")
      end
      if matches.empty? && named_spending_request?
        return result(:spending, "I could not match that request to one saved household spending category. Use its exact name or ask for all spending categories. No records changed.", total_count: rows.length, shown_count: 0, coverage: "category_not_found")
      end
      selected = matches.any? ? matches : rows
      shown = selected.first(MAX_RECORDS)
      available = plan.fetch(:plan_available)
      drafts = @household.transaction_drafts.pending.where(financial_source_event_id: nil, occurred_on: @reference_date..@reference_date.end_of_month).includes(:transaction_draft_splits).to_a
      blocks = []
      records = shown.map do |row|
        cell = row.fetch(:months).fetch(@reference_date.month - 1)
        allocation_known = available && !cell.fetch(:allocation_missing)
        estimate = allocation_known ? nil : spending_starting_estimate(row)
        pending = pending_category_cents(row, drafts)
        planned = if allocation_known
          "saved monthly plan #{money(cell[:planned])}"
        elsif estimate
          "no saved monthly allocation; setup starting estimate #{money(estimate)} (not approved for this month)"
        else
          "no saved monthly allocation; planned amount unknown"
        end
        actual = available ? "confirmed actuals recorded #{money(cell[:actual])}" : "confirmed actuals unavailable in this plan preview"
        blocks << "#{label(row[:name])} — #{row[:stack_label]}#{row[:active] ? '' : ' (archived category retained for history)'}: #{planned}; #{actual}; pending proposed category spending #{money(Money.dollars(pending))}, excluded from actuals."
        { id: row[:id], name: row[:name], stack_key: row[:stack_key], active: row[:active], allocation_known: allocation_known,
          planned_amount: allocation_known ? cell[:planned] : nil, starting_estimate: estimate,
          confirmed_actual_amount: available ? cell[:actual] : nil, pending_amount: Money.dollars(pending) }
      end
      footer = []
      active = rows.select { |row| row[:active] }
      if matches.empty? && available && active.any? && active.all? { |row| !row[:months][@reference_date.month - 1][:allocation_missing] }
        total = active.sum { |row| Money.cents(row[:months][@reference_date.month - 1][:planned]) }
        footer << "Saved active category plan across all #{active.length} categories: #{money(Money.dollars(total))}. This excludes debt minimums and archived category allocations."
      end
      footer << "#{drafts.length} pending household transaction #{'review'.pluralize(drafts.length)} recorded in #{month_label}, totaling #{money(Money.dollars(drafts.sum(&:total_amount_cents)))}; these have not changed confirmed actuals. Unassigned pending categories may not appear in the category amounts above."
      footer << "Pending budget edit cards are proposals; they do not change the saved plan amounts above until you apply reviewed changes."
      footer << "Recorded actuals cover confirmed or reconciled household records only. A recorded $0 does not verify no spending or complete coverage. This household plan is separate from the challenge's approved spending baseline and reserved savings."
      included = []
      blocks.each do |block|
        proposed = spending_answer_text(selected.length, included + [ block ], available, footer)
        break if proposed.length > ChatMessage::MAX_ASSISTANT_CONTENT_LENGTH
        included << block
      end
      records = records.first(included.length)
      result(:spending, spending_answer_text(selected.length, included, available, footer), total_count: selected.length, shown_count: records.length, coverage: selected.length > records.length ? "bounded_saved_records" : "all_matching_records", plan_available: available, records: records)
    end

    def spending_answer_text(total, blocks, available, footer)
      lead = [ "Household spending plan for #{month_label}. #{coverage_sentence(total, blocks.length)}" ]
      lead << "No saved monthly budget plan is available for this year. Setup starting amounts below are estimates, not saved monthly allocations; confirmed actual coverage is unavailable from this preview." unless available
      lead << "No spending categories or setup expense rows are saved. Spending and planned amounts remain unknown; this does not establish $0 or complete coverage." if total.zero?
      (lead + blocks + footer).join("\n\n")
    end

    def spending_category_matches(rows)
      text = normalized_category_text(@read_text)
      spans = rows.flat_map do |row|
        name = normalized_category_text(row[:name])
        next [] if name.blank?
        text.to_enum(:scan, /(?<![[:alnum:]])#{Regexp.escape(name)}(?![[:alnum:]])/).map do
          match = Regexp.last_match
          { row: row, starts_at: match.begin(0), ends_at: match.end(0) }
        end
      end
      spans.reject do |span|
        spans.any? { |other| other[:starts_at] <= span[:starts_at] && other[:ends_at] >= span[:ends_at] && other[:ends_at] - other[:starts_at] > span[:ends_at] - span[:starts_at] }
      end.map { |span| span[:row] }.uniq
    end

    def named_spending_request?
      return false if @read_text.match?(/\b(?:categories|expense stacks?|by category)\b/i)
      target = @read_text[/\b(?:my|our)\s+(?:household\s+)?(.+?)\s+(?:budget|planned amount|spending plan)\b/i, 1]
      target.present? && !target.match?(/\A(?:household|saved|monthly|current|next month|last month|this month)\z/i)
    end

    def spending_starting_estimate(row)
      expenses = @household.expense_items.where(active: true, stack_key: row[:stack_key]).where("LOWER(label) = ?", row[:name].downcase).to_a
      return unless expenses.one?
      Money.dollars(Money.period_cents(expenses.sole.amount_cents, expenses.sole.cadence, month: @reference_date.month))
    end

    def pending_category_cents(row, drafts)
      drafts.sum do |draft|
        splits = draft.transaction_draft_splits.to_a
        if splits.empty?
          row[:id].positive? && draft.budget_category_id == row[:id] ? draft.total_amount_cents : 0
        else
          splits.sum do |split|
            matched = row[:id].positive? && split.budget_category_id == row[:id]
            matched ||= row[:id].positive? && split.budget_category_id.nil? && split.category_name.to_s.casecmp?(row[:name]) && (split.stack_key.blank? || split.stack_key == row[:stack_key])
            matched ? split.amount_cents : 0
          end
        end
      end
    end

    def normalized_category_text(value) = value.to_s.unicode_normalize(:nfkc).downcase.gsub(/[^[:alnum:]]/, " ").squish

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
      if @read_text.match?(/\b(?:primary|main|household)\s+goal\b/i) && !@read_text.match?(/\btracked\b/i)
        goal = @household.primary_goal
        answer = goal.present? ? "Your saved primary household goal is: #{label(goal)}" : "No primary household goal is saved yet. This does not mean you have no tracked goals or challenge target."
        return result(:primary_goal, "#{answer}\n\nThis is your qualitative household goal, separate from tracked goal amounts and the challenge's accepted savings target. No records changed.", value: goal)
      end
      if !@read_text.match?(/\b(?:goals|tracked)\b/i)
        return if @read_text.match?(/\A(?:what(?:'s| is)|show(?: me)?|tell me)\s+(?:my|our)\s+goal[?.!]*\z/i)
        named = @household.goals.tracked.active.any? do |goal|
          name = normalized_category_text(goal.label)
          name.present? && normalized_category_text(@read_text).match?(/(?<![[:alnum:]])#{Regexp.escape(name)}(?![[:alnum:]])/)
        end
        return unless named
      end
      scope = @household.goals.tracked.active.order(:priority, :id)
      rows = scope.limit(MAX_RECORDS).map do |goal|
        "#{label(goal.label)} (#{goal.goal_type.humanize}): target #{known_money(goal.target_amount_known?, goal.target_amount_cents)}, recorded progress #{known_money(goal.current_amount_known?, goal.current_amount_cents)}, target date #{goal.target_on&.iso8601 || 'unknown'}."
      end
      inventory_result(:goals, scope.count, rows, "These are household tracked goals. They do not move money or change the challenge's accepted savings target, reserved money, or reported progress.")
    end

    def inventory_result(topic, total, rows, note)
      display_topic = topic == :goals ? "tracked goals" : topic.to_s
      lead = total.zero? ? "No active #{display_topic} are saved in your household plan. This does not establish zero balances or complete coverage." : "Saved household #{display_topic}: #{coverage_sentence(total, rows.length)}"
      result(topic, ([ lead ] + rows + [ note ]).join("\n\n"), total_count: total, shown_count: rows.length, coverage: total > rows.length ? "bounded_saved_records" : "all_saved_records")
    end

    def result(topic, answer, metadata = {})
      Result.new(answer: answer, metadata: metadata.merge(kind: "saved_financial_records", topic: topic.to_s, scope: "saved_household", reference_month: @reference_date.iso8601, write_state: "no_write"))
    end

    def coverage_sentence(total, shown)
      total > shown ? "Showing #{shown} of #{total} saved records; open My Money for the rest." : "Showing all #{total} saved #{'record'.pluralize(total)}."
    end

    def label(value) = value.to_s.gsub(/[[:cntrl:]]/, " ").squish
    def month_label = @reference_date.strftime("%B %Y")
    def cadence(value) = { "weekly" => "per week", "biweekly" => "every two weeks", "semi_monthly" => "twice a month", "monthly" => "per month", "annual" => "per year", "one_time" => "one time" }.fetch(value, value.to_s)
    def known_money(known, cents) = known ? money(Money.dollars(cents)) : "unknown"
    def money(dollars) = ActiveSupport::NumberHelper.number_to_currency(dollars, precision: 2)
  end
end
