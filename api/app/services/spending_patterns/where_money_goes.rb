module SpendingPatterns
  # "Where is my money going?" is about every category, not only what she could cut. Rails states the
  # totals and the plan beside them, so there is nothing for a narrator to round or rename, and nothing
  # here suggests a cut.
  class WhereMoneyGoes
    QUESTION = /\bwhere\b[^.?!]{0,30}\b(?:money|paychecks?|pay|income|cash|it\s+all)\b[^.?!]{0,20}\b(?:go|goes|going|went|gone|ends?\s+up)\b|\bwhat\b[^.?!]{0,20}\b(?:eat(?:s|ing)?\s+up|tak(?:es|ing)\s+up)\b[^.?!]{0,20}\b(?:money|paycheck|budget)\b/i

    # "… last month compared to the plan?": this answer always sets the plan beside the totals, so the
    # comparison is not part of the period.
    PLAN_TAIL = /\s*,?\s*(?:compared\s+(?:to|with)|against|vs\.?|versus)\s+(?:the|our|my)\s+(?:plan|budget)\s*([?.!]*)\z/i

    def self.question?(message) = message.to_s.match?(QUESTION)
    def self.period_text(message) = message.to_s.sub(PLAN_TAIL, '\1')

    # period_label: the month or dates she asked about ("June 2026"), when she named one.
    def initialize(household, patterns, period_label: nil, today: Time.current.in_time_zone("Pacific/Guam").to_date)
      @household, @patterns, @period_label, @today = household, patterns, period_label, today
    end

    def call
      categories = @patterns[:categories].first(3)
      return "I don’t have reviewed purchases to show where your money went yet. You can review a statement or tell me about a few purchases to start." if categories.empty?

      months = @patterns[:coverage][:months]
      present = months.select { |row| row[:spending_cents] }.map { |row| Date.iso8601("#{row[:month]}-01").strftime("%b") }
      missing = months.any? { |row| row[:spending_cents].nil? }
      window = if missing
        "#{"For #{@period_label}, " if @period_label}I only see purchases for #{present.to_sentence}:"
      elsif @period_label
        "For #{@period_label} in your reviewed purchases,"
      else
        present.one? ? "In #{present.first} in your reviewed purchases," : "From #{present.first} to #{present.last} in your reviewed purchases,"
      end
      parts = [ "#{window} most of your money went to #{categories.map { |row| "#{row[:label]} (#{money(row[:total_cents])})" }.to_sentence}." ]
      if (plan = plan_line(categories))
        parts << plan
        parts << "#{@today.strftime('%B')} is still going, so its plan isn’t used up yet." if months.last[:month] == @today.strftime("%Y-%m") && @today < @today.end_of_month
      end
      stores = @patterns[:merchants].first(3)
      parts << "The places you paid most were #{stores.map { |row| "#{row[:label]} (#{money(row[:total_cents])})" }.to_sentence}." if stores.any?
      parts << "This counts only purchases you’ve reviewed or confirmed. Does any of that surprise you?"
      parts.compact.join(" ")
    end

    private

    # Only when every month in the window has an approved plan for these categories.
    def plan_line(categories)
      planned = planned_by_category
      return unless planned

      total = @patterns[:observed_spending_cents]
      compared = categories.filter_map { |row| planned[row[:label].to_s.downcase]&.then { |cents| "#{row[:label]} #{money(row[:total_cents])} of #{money(cents)}" } }
      return if compared.empty?

      all_planned = planned.values.sum
      months = @patterns[:coverage][:months]
      span = months.one? ? "for #{Date.iso8601("#{months.first[:month]}-01").strftime('%B')}" : "for those months"
      "Against your plan #{span}: #{compared.to_sentence}. In all, #{money(total)} went out against #{money(all_planned)} planned for spending."
    end

    def planned_by_category
      months = @patterns[:coverage][:months].map { |row| Date.iso8601("#{row[:month]}-01") }
      return if months.empty? || months.first < HouseholdFinance::PlanCoverage.new(@household).starts_on

      months.group_by(&:year).each_with_object(Hash.new(0)) do |(year, in_year), totals|
        plan = HouseholdFinance::AnnualBudgetManager.new(@household, year: year).read_only_plan_data.deep_symbolize_keys
        return unless plan.fetch(:plan_available, true)

        Array(plan[:rows]).select { |row| row.fetch(:active, true) }.each do |row|
          in_year.each do |month|
            cell = Array(row[:months])[month.month - 1].to_h
            return if cell.empty? || cell[:allocation_missing]

            totals[row[:name].to_s.downcase] += HouseholdFinance::Money.cents(cell[:planned])
          end
        end
      end
    end

    def money(cents) = Answerer.money(cents)
  end
end
