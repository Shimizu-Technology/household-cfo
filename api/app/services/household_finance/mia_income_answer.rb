# frozen_string_literal: true

module HouseholdFinance
  # Rails supplies approved income and plan comparisons.
  class MiaIncomeAnswer
    QUESTION = /\bhow much\b[^?.!]{0,30}\b(?:came|come|comes|coming)\s+in\b|\bhow much\b[^?.!]{0,30}\b(?:did|do|does|have|will)\s+(?:we|i|you)\s+(?:earn|make|bring\s+in|get\s+paid)\b|\bhow much\b[^?.!]{0,20}\b(?:did|have)\s+(?:we|i)\s+(?:earned|made|brought\s+in|gotten\s+paid|been\s+paid)\b|\bhow much\s+(?:money\s+)?(?:did|do)\s+(?:we|i)\s+(?:get\s+)?paid\b/i
    # A question about a purchase, a change to the plan or a "what if" is not a
    # question about what arrived.
    EXCLUDED = /\b(?:if|would|could|should|afford|add|set|change|update|save|record|log|spent|spend|spending|vs|versus)\b|\b(?:went|go(?:es|ing)?)\s+out\b/i
    PLAN_COMPARISON = /\b(?:vs\.?|versus|compared (?:to|with)|against)\s+(?:(?:my|our|the)\s+)?(?:income\s+)?plan\s*[?.!]*\z/i
    # A purchase, payment or new figure in the same message is for the card, not this answer.
    REPORTED_AMOUNT = /\$\s?\d|\b\d{1,3}(?:,\d{3})+(?:\.\d{2})?\b|\b\d+\.\d{2}\b/
    WEEK = /\b(?:this|last|past)\s+week\b|\btoday\b|\byesterday\b/i
    YEAR = /\b(?:this|last|past)\s+year\b|\byear[- ]to[- ]date\b|\bytd\b/i

    # Saved-records questions ("what's my income?") keep their own detailed answer,
    # but no income question is ever answered with spending.
    TOPIC = /\b(?:what(?:s|['’]s| is| was| are| were)|how much|show|list|tell me)\b[^?.!]{0,25}\b(?:income|salary|salaries|paychecks?|wages?)\b/i

    def self.question?(message)
      text = message.to_s.squish
      return false if MessageReplyIntent.purchase_question?(text) || text.match?(REPORTED_AMOUNT) || MiaCoachAnswerer.spend_report_text?(text)
      current = ParticipantMessageReader::Current
      return false if current.message.to_s.squish == text && current.reading&.facts&.any?

      income_question = text.sub(PLAN_COMPARISON, "").strip
      return true if income_question != text && income_question.match?(/\A(?:actual\s+)?income\z/i)

      income_question.match?(QUESTION) && !income_question.match?(EXCLUDED)
    end

    def self.topic?(message)
      text = message.to_s.squish
      question?(text) || (text.match?(TOPIC) && !text.match?(EXCLUDED) && !MessageReplyIntent.purchase_question?(text))
    end

    def initialize(household, message:, annual_plan: nil)
      @household, @message, @annual_plan = household, message, annual_plan
    end

    def response
      text = @message.to_s
      today = Time.current.in_time_zone("Pacific/Guam").to_date
      year = text.match?(/\blast\s+year\b/i) ? today.year - 1 : text[/\b(20\d{2})\b/, 1]&.to_i
      # A month she names, or this/last month, is the period even with "so far" or a year beside it.
      if (month = MonthTerms.detect_number(text))
        return month_response(Date.new(year || MiaMonthAnswer.question_date(text, today: today).year, month, 1))
      end
      return month_response(MiaMonthAnswer.question_date(text, today: today)) if text.match?(/\b(?:this|last|next)\s+month\b|\b20\d{2}-\d{1,2}\b/i)
      return year_response(today, year || today.year) if text.match?(YEAR) || year
      return "I only have your income by month, not by day or week. #{month_response(today.beginning_of_month)}" if text.match?(WEEK)

      month_response(MiaMonthAnswer.question_date(text, today: today))
    end

    private

    def month_response(date)
      return "Which month and year do you mean? Please use a valid month, such as October 2026." unless date

      facts = MiaMonthAnswer.new(@household, annual_plan: plan_for(date.year), month: date.month).call
      actual = facts.fetch(:actual_income)
      received = actual[:actual_cents]
      lead = received.nil? ? "Income for #{facts[:period_label]} is not known yet." : "#{money(received)} came in for #{facts[:period_label]} from the lines you approved."
      "#{lead} #{plan_note(facts)} #{actual[:coverage_note]}"
    end

    # One total for the months that are known, then the months that are partly covered or not known, by name.
    def year_response(today, year)
      plan = plan_for(year)
      last = year == today.year ? today.month : 12
      facts = (1..last).map { |month| MiaMonthAnswer.new(@household, annual_plan: plan, month: month).call }
      known, unknown = facts.partition { |month| !month.dig(:actual_income, :actual_cents).nil? }
      partial = known.select { |month| month.dig(:actual_income, :partial) }
      planned = facts.select { |month| month[:plan_available] && !month[:before_plan_start] && !month[:money_in_cents].nil? }
      start = facts.find { |month| month[:before_plan_start] }
      parts = [ known.any? ? "#{money(known.sum { |month| month.dig(:actual_income, :actual_cents) })} came in for #{month_names(known, year)} from the lines you approved." : "Income for #{year} is not known yet." ]
      parts << "You planned #{money(planned.sum { |month| month[:money_in_cents] })} for #{planned.map { |month| month[:month] } == known.map { |month| month[:month] } ? (known.one? ? 'that month' : 'those months') : month_names(planned, year)}." if planned.any?
      parts << "#{month_names(partial, year)} #{partial.one? ? 'is' : 'are'} only partly covered, so #{partial.one? ? 'it shows' : 'they show'} the income approved so far." if partial.any?
      parts << "Not known yet: #{month_names(unknown, year)}." if unknown.any? && known.any?
      if start
        parts << "Your plan starts in #{Date.iso8601(start[:plan_starts_on]).strftime('%B %Y')}."
      elsif facts.none? { |month| month[:plan_available] }
        parts << "Your #{year} plan isn’t set up yet."
      end
      waiting = facts.sum { |month| month.dig(:actual_income, :waiting_deposits).to_i }
      parts << ActualIncome.waiting_note(waiting) if waiting.positive?
      parts.join(" ")
    end

    def plan_for(year)
      @plans ||= {}
      @plans[year] ||= if @annual_plan && (@annual_plan[:year] || @annual_plan["year"]).to_i == year
        @annual_plan
      else
        AnnualBudgetManager.new(@household, year: year).read_only_plan_data
      end
    end

    def plan_note(facts)
      return "Your plan starts in #{Date.iso8601(facts[:plan_starts_on]).strftime('%B %Y')}." if facts[:before_plan_start]
      return "Your #{facts[:year]} plan isn’t set up yet." unless facts[:plan_available]

      facts[:money_in_cents].nil? ? "There is no income plan for this month." : "You planned #{money(facts[:money_in_cents])}."
    end

    # "January to March and May 2026".
    def month_names(months, year)
      runs = months.map { |month| month[:month] }.slice_when { |left, right| right != left + 1 }
      "#{runs.map { |run| run.one? ? Date::MONTHNAMES[run.first] : "#{Date::MONTHNAMES[run.first]} to #{Date::MONTHNAMES[run.last]}" }.to_sentence} #{year}"
    end

    def money(cents)
      ActiveSupport::NumberHelper.number_to_currency(Money.dollars(cents), precision: cents.modulo(100).zero? ? 0 : 2)
    end
  end
end
