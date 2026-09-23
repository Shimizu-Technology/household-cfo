# frozen_string_literal: true

module HouseholdFinance
  class DebtStrategyPlanner
    QUESTION_PATTERN = /\b(?:debt (?:plan|strategy|management|payoff)|pay (?:down|off) (?:my |our )?(?:debt|cards?|loans?)|which (?:debt|card|loan)|avalanche|snowball|highest (?:apr|interest)|smallest balance|extra (?:debt )?payment|use (?:it|this|the .{0,20}) (?:on|for|toward) debt|plan for (?:my |our )?debt)\b/i.freeze
    TEMPORARY_INCOME_PATTERN = /(?:income|pay|take-home).{0,35}(?:down|drop|reduc|cut|lower).{0,20}\$\s*((?:\d{1,3}(?:,\d{3})+|\d{1,9})(?:\.\d{1,2})?)/i.freeze
    DOLLAR_PATTERN = /\$\s*((?:\d{1,3}(?:,\d{3})+|\d{1,9})(?:\.\d{1,2})?)/.freeze
    SCENARIO_VALUES_PATTERN = /\$\s*(?<balance>[\d,]+(?:\.\d{1,2})?)\s*(?:balance\s*)?(?:at|with|,|and)?\s*(?:a\s*)?(?<apr>[\d.]+)\s*%\s*(?:APR|interest).*?\$\s*(?<minimum>[\d,]+(?:\.\d{1,2})?)\s*(?:monthly\s*)?(?:minimum|min)/i.freeze
    MONTH_WORDS = {
      "one" => 1, "two" => 2, "three" => 3, "four" => 4, "five" => 5, "six" => 6,
      "seven" => 7, "eight" => 8, "nine" => 9, "ten" => 10, "eleven" => 11, "twelve" => 12
    }.freeze
    RECENT_USER_MESSAGE_LIMIT = 6

    def self.question?(message)
      text = message.to_s
      text.match?(QUESTION_PATTERN) || (text.match?(/\bdebt\b/i) && text.match?(/\b(?:concrete|detailed|three-step|step-by-step)\b.{0,40}\bplan\b|\bplan\b.{0,80}\bdebt\b/i))
    end

    def initialize(household, message, conversation_messages: [])
      @household = household
      @message = message.to_s.squish
      @conversation_messages = Array(conversation_messages)
    end

    def call
      return unless self.class.question?(message) || debt_plan_followup?

      approved_debts = household.debts.order(:id).to_a
      scenario_debts = parsed_scenario_debts
      approved_keys = approved_debts.index_by { |debt| debt_identity(debt_label(debt)) }
      scenario_only_debts = scenario_debts.reject { |debt| approved_keys.key?(debt_identity(debt_label(debt))) }
      debts = approved_debts + scenario_only_debts
      return missing_debts_answer if debts.empty?

      avalanche = debts.select { |debt| debt_value(debt, :interest_rate_percent).present? }
        .max_by { |debt| [ debt_value(debt, :interest_rate_percent).to_d, debt_value(debt, :balance_cents).to_i ] }
      snowball = debts.select { |debt| debt_value(debt, :balance_cents).to_i.positive? }
        .min_by { |debt| [ debt_value(debt, :balance_cents).to_i, -debt_value(debt, :interest_rate_percent).to_d ] }
      minimums = debts.sum { |debt| debt_value(debt, :minimum_payment_cents).to_i }
      snapshot = SnapshotBuilder.new(household).call
      temporary_drop = temporary_income_drop_cents
      scenario_minimums = scenario_only_debts.sum { |debt| debt_value(debt, :minimum_payment_cents).to_i }
      adjusted_surplus = snapshot.fetch(:baseline_surplus_cents) - temporary_drop - scenario_minimums
      extra_amount = decision_amount_cents

      lines = []
      lines << source_line(approved_debts, scenario_debts, scenario_only_debts, debts)
      lines << "Avalanche: #{strategy_target(avalanche, include_apr: true)}" if avalanche
      lines << "Avalanche needs each APR before I can rank the debts honestly." unless avalanche
      lines << "Snowball: #{strategy_target(snowball, include_apr: false)}" if snowball
      minimum_label = debts.length == 2 ? "Keep both minimums current first" : "Keep every required minimum current first"
      lines << "#{minimum_label} (#{money(minimums)} total across the debts listed)."
      lines << temporary_income_line(temporary_drop, adjusted_surplus) if temporary_drop.positive?
      lines << extra_money_line(extra_amount, avalanche, snowball, snapshot) if extra_amount.positive?
      lines << numbered_plan(avalanche, snowball, adjusted_surplus)
      lines << missing_apr_line(debts)
      lines.compact_blank.join(" ")
    end

    private

    attr_reader :household, :message, :conversation_messages

    def source_line(approved_debts, scenario_debts, scenario_only_debts, debts)
      source = approved_debts.any? ? "approved debt records" : "the participant-stated scenario"
      details = debts.map do |debt|
        origin = scenario_only_debts.include?(debt) ? "scenario only, not saved" : "saved"
        "#{debt_label(debt)} (#{origin}): #{money(debt_value(debt, :balance_cents))} balance and #{money(debt_value(debt, :minimum_payment_cents))} monthly minimum"
      end
      scenario_note = if scenario_debts.any? && approved_debts.any?
        " The participant-stated scenario adds debts that do not match a saved label only for this comparison; matching statements do not overwrite saved records."
      elsif scenario_only_debts.any?
        " These participant-stated facts are not saved as approved household records."
      end
      "Here is the comparison using #{source}.#{scenario_note} Debt details: #{details.join('; ')}."
    end

    def strategy_target(debt, include_apr:)
      return "not available until at least one balance is entered." unless debt

      details = [ "#{debt_label(debt)} first", "#{money(debt_value(debt, :balance_cents))} balance" ]
      apr = debt_value(debt, :interest_rate_percent)
      details << "#{number(apr)}% APR" if include_apr && apr.present?
      "#{details.join(', ')}."
    end

    def numbered_plan(avalanche, snowball, adjusted_surplus)
      target = avalanche || snowball
      extra = [ adjusted_surplus, 0 ].max
      target_line = target ? "#{debt_label(target)}" : "the selected target debt"
      if extra.positive?
        "1. Protect essential bills and every debt minimum. 2. Hold emergency runway and known near-term expenses aside. 3. Send a fixed amount of up to #{money(extra)} from the current monthly surplus to #{target_line}; choose avalanche for lower interest cost or snowball for the fastest closed balance. No payment is made automatically."
      else
        "1. Protect essential bills and every debt minimum. 2. Hold emergency runway and pause new card spending. 3. Do not schedule extra principal while the adjusted baseline is negative; contact issuers before a due date if a minimum is at risk, then restart with #{target_line} when cash flow recovers. No payment is made automatically."
      end
    end

    def temporary_income_line(drop_cents, adjusted_surplus)
      duration = temporary_income_months
      duration_text = duration ? " for #{duration == 1 ? 'one month' : "#{duration_in_words(duration)} months"}" : ""
      "With the #{money(drop_cents)} temporary monthly income drop#{duration_text}, the modeled monthly surplus becomes #{money(adjusted_surplus)}."
    end

    def extra_money_line(amount, avalanche, snowball, snapshot)
      runway_months = snapshot.fetch(:runway_months).to_f
      protection = if runway_months < 1
        "Because recorded runway is under one month, keep enough of the #{money(amount)} to cover the next essential-bill and minimum-payment gap before sending the remainder to principal."
      else
        "Keep protected runway and known near-term bills intact before using any of the #{money(amount)} for principal."
      end
      targets = [ avalanche && "avalanche targets #{debt_label(avalanche)}", snowball && "snowball targets #{debt_label(snowball)}" ].compact.join("; ")
      decision_note = if message.match?(/tax refund/i)
        "Treat the #{money(amount)} tax refund as available only after it clears; this plan does not determine tax eligibility or obligations. "
      else
        ""
      end
      "#{decision_note}#{protection} After that guardrail, #{targets}."
    end

    def missing_apr_line(debts)
      missing = debts.select { |debt| debt_value(debt, :interest_rate_percent).blank? }.map { |debt| debt_label(debt) }
      return if missing.empty?

      "APR is still missing for #{missing.to_sentence}; verify those rates on the latest statements before treating the avalanche ranking as complete."
    end

    def parsed_scenario_debts
      @parsed_scenario_debts ||= begin
        text = recent_user_conversation
        text.split(/(?<=[.!?])\s+/).filter_map do |sentence|
          values = sentence.match(SCENARIO_VALUES_PATTERN)
          next unless values

          label = scenario_label(sentence[0...values.begin(0)])
          next if label.blank?

          {
            label: label,
            balance_cents: dollars_to_cents(values[:balance]),
            interest_rate_percent: BigDecimal(values[:apr]),
            minimum_payment_cents: dollars_to_cents(values[:minimum])
          }
        end.uniq { |debt| debt_identity(debt.fetch(:label)) }
      end
    end

    def scenario_label(prefix)
      prefix.to_s
        .sub(/\A.*?\b(?:I|we)\s+(?:also\s+)?have\s+(?:an?\s+|the\s+)?/i, "")
        .sub(/\s+(?:that|which)\b.*\z/i, "")
        .sub(/\s+(?:is|has|balance(?:\s+is)?|saved\s+at)\s*\z/i, "")
        .sub(/[:;,\-\s]+\z/, "")
        .squish
        .truncate(60, omission: "…")
    end

    def debt_identity(label)
      label.to_s.downcase.gsub(/\b(?:a|an|the|credit|card|loan|debt)\b/, " ").gsub(/[^a-z0-9]/, "").presence || label.to_s.downcase
    end

    def temporary_income_drop_cents
      match = recent_user_conversation.match(TEMPORARY_INCOME_PATTERN)
      match ? dollars_to_cents(match[1]) : 0
    end

    def temporary_income_months
      match = recent_user_conversation.match(/(?:for|over)\s+(?:the\s+)?(?:next\s+)?(\d+|#{MONTH_WORDS.keys.join('|')})\s+months?/i)
      return unless match

      MONTH_WORDS.fetch(match[1].downcase, match[1].to_i).clamp(1, 24)
    end

    def duration_in_words(duration)
      MONTH_WORDS.key(duration) || duration.to_s
    end

    def decision_amount_cents
      return 0 unless message.match?(/refund|bonus|windfall|extra money|lump sum/i)

      match = message.match(/#{DOLLAR_PATTERN}.{0,45}?(?:refund|bonus|windfall|extra money|lump sum)/i) ||
        message.match(/(?:refund|bonus|windfall|extra money|lump sum).{0,45}?#{DOLLAR_PATTERN}/i)
      match ? dollars_to_cents(match.captures.compact.last) : 0
    end

    def recent_user_messages
      @recent_user_messages ||= conversation_messages.filter_map do |entry|
        role = entry.respond_to?(:role) ? entry.role : entry[:role] || entry["role"]
        content = entry.respond_to?(:content) ? entry.content : entry[:content] || entry["content"]
        content if role.to_s == "user"
      end.last(RECENT_USER_MESSAGE_LIMIT)
    end

    def recent_user_conversation
      @recent_user_conversation ||= ([ *recent_user_messages, message ]).join(" ")
    end

    def debt_plan_followup?
      followup_signal = message.match?(/\b(?:now|next|then|that|this|those|same|continue|what (?:do|should) i do|income (?:is |has )?(?:down|dropp|reduc|cut|lower))\b/i)
      followup_signal && recent_user_messages.join(" ").match?(/\b(?:debt|credit card|loan|APR)\b/i)
    end

    def missing_debts_answer
      "I can build an avalanche or snowball plan, but I need each debt's label, current balance, minimum payment, and APR first. Add them under My Profile or list them here as a scenario. Nothing will be changed or paid automatically."
    end

    def debt_value(debt, key)
      debt.respond_to?(key) ? debt.public_send(key) : debt[key]
    end

    def debt_label(debt)
      debt_value(debt, :label).to_s
    end

    def dollars_to_cents(value)
      (BigDecimal(value.to_s.delete(",")) * 100).round.to_i
    end

    def number(value)
      value.to_d.to_s("F").sub(/\.0+\z/, "").sub(/(\.\d*?)0+\z/, "\\1")
    end

    def money(cents)
      ActiveSupport::NumberHelper.number_to_currency(
        Money.dollars(cents),
        precision: cents.to_i % 100 == 0 ? 0 : 2
      )
    end
  end
end
