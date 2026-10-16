module HouseholdFinance
  class SpendingReportNarrator
    BUDGET_STATUS_TERMS = /\b(staying within|within (?:my|our|the)?\s*budget|under budget|over budget|over plan|under plan|on track|off track|am i okay|are we okay)\b/i
    CATEGORY_STATUS_TERMS = /\b(?:what|which)\s+categories\b.*\b(?:over|under)\b.*\b(?:plan|budget)\b/i

    def initialize(report, prompt: nil)
      @report = report.deep_symbolize_keys
      @prompt = prompt.to_s
    end

    def call
      totals = report.fetch(:totals)
      categories = report.fetch(:categories)
      bank = report[:bank_activity] || {}
      top_categories = categories.sort_by { |category| -category.fetch(:actual).to_f }.first(3)
      top_line = top_categories.select { |category| category.fetch(:actual).positive? }.map do |category|
        "#{category.fetch(:name)} #{money(category.fetch(:actual))}"
      end.to_sentence
      top_line = "No confirmed category spending yet" if top_line.blank?

      return category_status_answer(categories, totals) if category_status_question?
      return budget_status_answer(totals, top_line) if budget_status_question?

      focused = merchant_focus_answer || category_focus_answer(categories)
      return focused if focused

      [
        spending_comparison_line(totals),
        pending_and_bank_line(totals),
        "Top actual categories: #{top_line}.",
        bank_merchant_line(bank),
        recent_transaction_line,
        closing_line(totals)
      ].compact.join("\n\n")
    end

    private

    attr_reader :report, :prompt

    def budget_status_question?
      prompt.match?(BUDGET_STATUS_TERMS)
    end

    def category_status_question?
      prompt.match?(CATEGORY_STATUS_TERMS)
    end

    def category_status_answer(categories, totals)
      unless plan_available?
        return "I can report confirmed spending for #{report.fetch(:period_label)}, but no approved historical plan is available for that period, so I cannot label categories over or under plan. Confirmed actuals are #{money(totals.fetch(:actual))}; pending drafts remain separate."
      end

      over_categories = categories.select { |category| category.fetch(:actual).to_f > category.fetch(:planned).to_f }
      pending_line = "Pending drafts waiting for your approval total #{money(totals.fetch(:pending))}; I am not counting those as actuals until you confirm them."
      if over_categories.empty?
        return [
          "No active category is #{over_word} for #{report.fetch(:period_label)}, based on confirmed transactions.",
          "Confirmed actuals are #{money(totals.fetch(:actual))} against #{planned_phrase(totals.fetch(:planned))}.",
          pace_note,
          pending_line,
          "Next CFO move: review pending drafts before treating the remaining plan as safe-to-spend."
        ].compact.join("\n\n")
      end

      over_line = over_categories.map do |category|
        over_by = category.fetch(:actual).to_f - category.fetch(:planned).to_f
        "#{category.fetch(:name)} over by #{money(over_by)}"
      end.to_sentence
      [
        "These categories are #{over_word} for #{report.fetch(:period_label)}, based on confirmed transactions: #{over_line}.",
        pace_note,
        pending_line,
        "Next CFO move: identify what was one-time versus repeat pattern before cutting essentials."
      ].compact.join("\n\n")
    end

    def budget_status_answer(totals, top_line)
      unless plan_available?
        return "I can report confirmed spending for #{report.fetch(:period_label)}, but no approved historical plan is available for that period, so I cannot say whether the household was within budget. Confirmed actuals are #{money(totals.fetch(:actual))}, and pending drafts total #{money(totals.fetch(:pending))}."
      end

      planned = totals.fetch(:planned).to_f
      actual = totals.fetch(:actual).to_f
      pending = totals.fetch(:pending).to_f
      bank_needs_review = totals.fetch(:bank_needs_review, 0).to_f
      non_plaid_pending = totals.fetch(:pending_non_plaid, 0).to_f
      remaining = totals.fetch(:remaining).to_f
      provisional = bank_needs_review + non_plaid_pending
      projected_remaining = planned - actual - provisional
      status_line = if remaining.negative?
        "No — based on confirmed transactions for #{report.fetch(:period_label)}, you are #{money(remaining.abs)} #{prorated? ? "over the plan so far" : "over the confirmed budget"}: #{money(actual)} actual against #{planned_phrase(planned)}."
      elsif provisional.positive? && projected_remaining.negative?
        "Almost — confirmed spending for #{report.fetch(:period_label)} is within #{prorated? ? "the plan so far" : "budget"}, but posted bank activity and other drafts awaiting review would put you #{money(projected_remaining.abs)} over if they are all valid."
      else
        "Yes — based on confirmed transactions for #{report.fetch(:period_label)}, you are within #{prorated? ? "the plan so far" : "budget"}: #{money(actual)} confirmed against #{planned_phrase(planned)}."
      end

      pending_line = provisional.positive? ? "Provisional outflows total #{money(provisional)}: #{money(bank_needs_review)} is posted bank activity needing review and #{money(non_plaid_pending)} comes from other drafts. Bank-pending charges remain separate." : "No posted outflows or other drafts are waiting for household review in this period."
      remaining_line = remaining.negative? ? "Confirmed actuals are over by #{money(remaining.abs)}#{prorated? ? " so far" : ""}. Top actual categories: #{top_line}." : "You have #{money(remaining)} left#{prorated? ? " of the plan so far" : " on confirmed actuals"}. Top actual categories: #{top_line}."
      next_move = remaining.negative? ? "Your next CFO move is to name what was one-time versus a repeat pattern before cutting essentials." : "Keep logging before the small purchases turn into a mystery, then make the next approval on purpose."

      [ status_line, remaining_line, pace_note, pending_line, next_move ].compact.join("\n\n")
    end

    def bank_merchant_line(bank)
      merchants = Array(bank[:top_merchants]).first(3)
      return if merchants.empty?

      details = merchants.map { |row| "#{row.fetch(:merchant)} #{money(row.fetch(:amount))} (#{row.fetch(:count)} #{'time'.pluralize(row.fetch(:count))})" }.to_sentence
      "Top bank-observed merchants: #{details}."
    end

    def recent_transaction_line
      transactions = Array(report[:transactions]).first(3)
      return if transactions.empty?

      details = transactions.map do |transaction|
        merchant = transaction[:merchant].presence || "Transaction"
        date = transaction[:occurred_on].present? ? Date.iso8601(transaction[:occurred_on]).strftime("%b %-d") : nil
        [ merchant, money(transaction[:amount]), date ].compact.join(" ")
      rescue ArgumentError
        [ transaction[:merchant].presence || "Transaction", money(transaction[:amount]) ].compact.join(" ")
      end.to_sentence
      "Recent confirmed transactions: #{details}."
    end

    def closing_line(totals)
      return "No approved historical plan is available for this period, so I am not treating $0 as the planned amount." unless plan_available?

      remaining = totals.fetch(:remaining).to_f
      return "You are #{money(remaining)} under the planned amount for this period so far." if remaining.positive?
      return "You are exactly at the planned amount for this period#{prorated? ? " so far" : ""}." if remaining.zero?

      "You are #{money(remaining.abs)} over the #{prorated? ? "plan so far (prorated #{through_label})" : "planned amount for this period"}. Review what was structural versus one-off before cutting essentials."
    end

    def spending_comparison_line(totals)
      observed = money(totals.fetch(:bank_observed, 0))
      actual = money(totals.fetch(:actual))
      unless bank_activity_present?(totals)
        return "For #{report.fetch(:period_label)}, confirmed spending is #{actual} against #{planned_phrase(totals.fetch(:planned))}." if plan_available?

        return "For #{report.fetch(:period_label)}, confirmed spending is #{actual}. No approved historical plan is available for this period, so no planned comparison is shown."
      end
      if plan_available?
        return "For #{report.fetch(:period_label)}, synced bank activity shows #{observed} in posted outflows; based on confirmed transactions, confirmed spending is #{actual} against #{planned_phrase(totals.fetch(:planned))}."
      end

      "For #{report.fetch(:period_label)}, synced bank activity shows #{observed} in posted outflows and confirmed spending is #{actual}. No approved historical plan is available for this period, so no planned comparison is shown."
    end

    def pending_and_bank_line(totals)
      pending = "Pending drafts waiting for your approval total #{money(totals.fetch(:pending))}."
      return pending unless bank_activity_present?(totals)

      "#{pending} Posted bank activity still needing household review totals #{money(totals.fetch(:bank_needs_review, 0))}; bank-pending activity totals #{money(totals.fetch(:bank_pending, 0))} and is excluded from posted spending."
    end

    # A household with no synced bank activity in the period should not read
    # about "synced bank activity" at all.
    def bank_activity_present?(totals)
      bank = report[:bank_activity] || {}
      [ totals.fetch(:bank_observed, 0), totals.fetch(:bank_needs_review, 0), totals.fetch(:bank_pending, 0), bank[:inflow].to_f ].any? { |value| value.to_f.positive? } ||
        bank[:posted_outflow_count].to_i.positive? || bank[:pending_count].to_i.positive? || bank[:inflow_count].to_i.positive?
    end

    # "And dining out?" asks about one category, not the whole month.
    def category_focus_answer(categories)
      named = categories.select { |category| category.fetch(:id).to_i.positive? && mentions?(category.fetch(:name)) }
      named = named.reject { |category| named.any? { |other| other != category && normalized(other.fetch(:name)).include?(normalized(category.fetch(:name))) } }
      return if named.empty?

      lines = named.first(3).map do |category|
        actual = category.fetch(:actual).to_f
        planned = category.fetch(:planned).to_f
        comparison = if !plan_available?
          ""
        elsif actual > planned
          " against #{planned_phrase(planned)}, #{money(actual - planned)} #{over_word}"
        else
          " against #{planned_phrase(planned)}, #{money(planned - actual)} #{prorated? ? "under the plan so far" : "under plan"}"
        end
        pending = category.fetch(:pending).to_f.positive? ? " Pending drafts there total #{money(category.fetch(:pending))} and are not counted until you confirm them." : ""
        "#{category.fetch(:name)} has #{money(actual)} in confirmed spending#{comparison}.#{pending}"
      end
      largest = category_transactions(named.first).max_by { |transaction| transaction[:amount].to_f }
      largest_line = largest ? " The largest confirmed charge there was #{transaction_label(largest)}." : ""
      "For #{report.fetch(:period_label)}: #{lines.join(' ')}#{largest_line}"
    end

    # "How much of that was Jollibee?" asks about one merchant.
    def merchant_focus_answer
      transactions = Array(report[:transactions])
      drafts = Array(report[:pending_drafts])
      merchant = (transactions + drafts).map { |row| row[:merchant].to_s }.compact_blank.uniq
        .select { |name| normalized(name).length >= 3 && mentions?(name) }
        .max_by(&:length)
      return unless merchant

      truncated = transactions.length >= SpendingReport::MAX_TRANSACTIONS
      scope = truncated ? "In the most recent #{SpendingReport::MAX_TRANSACTIONS} transactions of #{report.fetch(:period_label)}" : "For #{report.fetch(:period_label)}"
      matches = transactions.select { |transaction| normalized(transaction[:merchant]) == normalized(merchant) }
      pending = drafts.select { |draft| normalized(draft[:merchant]) == normalized(merchant) }
      total = matches.sum { |transaction| transaction[:amount].to_f }
      count = matches.length
      dates = matches.first(3).map { |transaction| transaction_label(transaction) }.to_sentence
      lead = if count.positive?
        "#{scope}, confirmed spending at #{merchant} is #{money(total)} across #{count} #{'transaction'.pluralize(count)}: #{dates}."
      else
        "#{scope}, there is no confirmed spending at #{merchant}."
      end
      pending_line = pending.any? ? " Pending drafts at #{merchant} total #{money(pending.sum { |draft| draft[:amount].to_f })} and are not counted until you confirm them." : ""
      share = !truncated && totals_actual.positive? && count.positive? ? " That is #{(total / totals_actual * 100).round}% of the #{money(totals_actual)} confirmed for the period." : ""
      "#{lead}#{share}#{pending_line}"
    end

    def category_transactions(category)
      Array(report[:transactions]).select { |transaction| Array(transaction[:categories]).include?(category.fetch(:name)) }
    end

    def transaction_label(transaction)
      date = Date.iso8601(transaction[:occurred_on].to_s).strftime("%b %-d") if transaction[:occurred_on].present?
      [ transaction[:merchant].presence || "Transaction", money(transaction[:amount]), date ].compact.join(" ")
    rescue ArgumentError
      [ transaction[:merchant].presence || "Transaction", money(transaction[:amount]) ].join(" ")
    end

    def totals_actual
      report.fetch(:totals).fetch(:actual).to_f
    end

    def mentions?(name)
      phrase = normalized(name)
      phrase.present? && normalized(prompt).match?(/(?<![a-z0-9])#{Regexp.escape(phrase)}(?![a-z0-9])/)
    end

    def normalized(value)
      value.to_s.downcase.delete("'’").gsub(/[^a-z0-9]+/, " ").squish
    end

    # The report's plan is prorated to the days covered. A part-month range
    # (like October on the 16th) must read as pace, never as a finished month.
    def prorated?
      start_on = Date.iso8601(report[:start_on].to_s)
      end_on = Date.iso8601(report[:end_on].to_s)
      whole_month = start_on == start_on.beginning_of_month && end_on == start_on.end_of_month
      whole_year = start_on == start_on.beginning_of_year && end_on == start_on.end_of_year
      !(whole_month || whole_year)
    rescue ArgumentError, TypeError
      false
    end

    def through_label
      "through #{Date.iso8601(report[:end_on].to_s).strftime('%b %-d')}"
    end

    def planned_phrase(planned)
      prorated? ? "#{money(planned)} planned so far (the plan prorated #{through_label})" : "#{money(planned)} planned"
    end

    def over_word
      prorated? ? "over the plan so far" : "over plan"
    end

    def pace_note
      return unless prorated? && plan_available?

      "This compares spending so far with the plan prorated #{through_label}, not the full-month plan."
    end

    def plan_available?
      report.fetch(:plan_available, true)
    end

    def money(value)
      cents = (value.to_f * 100).round
      ActiveSupport::NumberHelper.number_to_currency(value, precision: cents % 100 == 0 ? 0 : 2)
    end
  end
end
