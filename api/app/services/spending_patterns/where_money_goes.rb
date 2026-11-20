module SpendingPatterns
  # "Where is my money going?" is about every category, not only what she could cut. Rails states the
  # totals and the plan beside them, so there is nothing for a narrator to round or rename, and nothing
  # here suggests a cut.
  class WhereMoneyGoes
    # Where it went, or is going, now: "Where is my money going?", "Where did it all go?", "Where am I
    # spending the most?". Never a plan for money still to come ("Where should my tax refund go?",
    # "Where will the bonus go?", "Where is the money for rent going to come from?").
    QUESTION = /
      \bwhere\b(?![^.?!]*\b(?:should|shall|will|would|could|can|ought|going\s+to|gonna|come\s+from|comes\s+from|coming\s+from)\b)
      (?:[^.?!]{0,30}\b(?:money|paychecks?|pay|income|cash|it\s+all)\b[^.?!]{0,20}\b(?:go|goes|going|went|gone|ends?\s+up)\b
        |\s+(?:am\s+i|are\s+we|do\s+(?:i|we)|did\s+(?:i|we)|have\s+(?:i|we))\s+(?:been\s+)?(?:spend|spending|spent)\b)
      |\bwhat\b[^.?!]{0,20}\b(?:eat(?:s|ing)?\s+up|tak(?:es|ing)\s+up)\b[^.?!]{0,20}\b(?:money|paycheck|budget)\b
    /ix

    # "… last month compared to the plan?": this answer always sets the plan beside the totals, so the
    # comparison is not part of the period.
    PLAN_TAIL = /\s*,?\s*(?:compared\s+(?:to|with)|against|vs\.?|versus)\s+(?:the|our|my)\s+(?:plan|budget)\s*([?.!]*)\z/i

    def self.question?(message) = message.to_s.match?(QUESTION)
    def self.period_text(message) = message.to_s.sub(PLAN_TAIL, '\1')

    # Her question as asked: the month or dates she named ("in June"), or the recent months when she
    # named none. Returns [patterns, reply]; raises RequestedPeriod::Unsupported for a period it can't read.
    def self.reply(household, message, today: Time.current.in_time_zone("Pacific/Guam").to_date)
      period = RequestedPeriod.new(period_text(message), today: today).call
      patterns = Analyzer.new(household, today: today, **period).call
      return [ patterns, new(household, patterns, today: today).call ] if period.empty?

      label = period_label(period)
      return [ patterns, "I don’t have reviewed purchases for #{label}, so I can’t tell where your money went then. You can review a statement or tell me about purchases from that period." ] if patterns[:purchase_count].zero?

      [ patterns, new(household, patterns, period_label: label, today: today).call ]
    end

    def self.period_label(period)
      return period[:from].strftime("%B %Y") if period[:from] == period[:from].beginning_of_month && period[:to] == period[:from].end_of_month

      "#{period[:from].strftime('%B %-d, %Y')} through #{period[:to].strftime('%B %-d, %Y')}"
    end

    # period_label: the month or dates she asked about ("June 2026"), when she named one.
    def initialize(household, patterns, period_label: nil, today: Time.current.in_time_zone("Pacific/Guam").to_date)
      @household, @patterns, @period_label, @today = household, patterns, period_label, today
    end

    def call
      categories = @patterns[:categories].first(3)
      if categories.empty?
        return "I don’t have reviewed purchases to show where your money went yet. You can review a statement or tell me about a few purchases to start." if @patterns[:purchase_count].zero?

        # Bought and then refunded: there were purchases, they just net to nothing.
        return "Your reviewed purchases#{" for #{@period_label}" if @period_label} come to #{money(@patterns[:observed_spending_cents])} after the refunds you approved, so no category has money going to it. This counts only purchases you’ve reviewed or confirmed."
      end

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
      months = recorded_months
      span = months.one? ? "for #{Date.iso8601("#{months.first[:month]}-01").strftime('%B')}" : "for those months"
      "Against your plan #{span}: #{compared.to_sentence}. In all, #{money(total)} went out against #{money(all_planned)} planned for spending."
    end

    # Months with no reviewed purchases are unknown, not $0 against their plan. A month with only a
    # refund has no purchases either; its refund still counts in the total.
    def recorded_months = @patterns[:coverage][:months].select { |row| row[:purchase_count].positive? }

    def planned_by_category
      months = recorded_months.map { |row| Date.iso8601("#{row[:month]}-01") }
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
