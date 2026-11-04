module HouseholdFinance
  # Small, fully accounted-for setup statements need no model arithmetic. The
  # resulting operations still go through the ordinary review/apply boundary.
  class MiaSetupIntake
    NUMBER = "(#{Money::CHAT_NUMBER_SOURCE}(?!\\d|,\\d)#{Money::CHAT_THOUSANDS_SOURCE}?)"
    AMOUNT = "(?:\\s+(?:is|are|of))?\\s*(?:about\\s+)?\\$?\\s*#{NUMBER}"
    PATTERNS = {
      primary_income: /\b(?:(?:i|we)\s+bring\s+home|(?:(?:my|our)\s+)?monthly\s+(?:take-home\s+)?income)#{AMOUNT}/i,
      rent: /\brent#{AMOUNT}/i,
      utilities: /\butilities#{AMOUNT}/i,
      groceries: /\bgroceries#{AMOUNT}/i,
      car_minimum: /\b(?:the\s+)?car\s+(?:loan\s+)?(?:minimum|minimum\s+payment)#{AMOUNT}/i
    }.freeze
    GOAL = /\A(?:build|save)(?:\s+up)?\s+(?:a\s+)?\$\s*#{NUMBER}\s+(emergency\s+(?:cushion|fund)|for\s+emergencies)[.!]?\z/i

    def self.goal_target(text)
      match = text.to_s.squish.match(GOAL)
      match && Money.chat_cents(match[1])
    end

    def self.goal_label(text)
      label = text.to_s.squish.match(GOAL)&.[](2)
      label = "emergency fund" if label&.match?(/\Afor /i)
      label&.sub(/\A./, &:upcase)
    end

    def initialize(message, context: {})
      @message = message.to_s
      @context = context.deep_symbolize_keys
    end

    def call
      return if context.dig(:setup_status, :complete) != false
      return unless amounts

      stripped = text.dup
      PATTERNS.each_value { |pattern| stripped.gsub!(pattern, " ") }
      # Never swallow an unrecognized clause, hypothetical, cadence, or number.
      return unless stripped.match?(/\A(?:[\s,.;!]|\b(?:and|our|my|the|each month|per month|a month|monthly)\b)*\z/i)

      # A partial answer is useful too. Never fill an unstated field with zero.
      return if amounts.key?(:rent) != amounts.key?(:utilities)
      updates = {}
      updates[:primary_income] = dollars(amounts[:primary_income]) if amounts.key?(:primary_income)
      updates[:fixed_expenses] = dollars(fixed_cents) if fixed_cents
      updates[:flexible_spend] = dollars(amounts[:groceries]) if amounts.key?(:groceries)
      return if updates.empty?
      action = { type: "update_household_setup", setup_updates: updates }
      plan = {}
      if amounts.key?(:car_minimum)
        return unless context.dig(:debt_tracking, :mode).to_s != "summary" && Array(context[:active_debts]).empty?

        car = message.match(PATTERNS.fetch(:car_minimum))
        # Sources are exact, disjoint participant spans, just like model plans.
        return if message[car.end(0)..].to_s.gsub(MiaSetupGuide::SETUP_REQUEST, "").delete(".,! ").present?
        plan = { actions: [
          { source_text: message[0...car.begin(0)], depends_on: [], action: action },
          { source_text: car[0], depends_on: [], action: { type: "create_debt", debt_name: "Car loan", debt_type: "auto_loan", minimum_payment: dollars(amounts.fetch(:car_minimum)) } }
        ] }
        action = { type: "none" }
      end
      MiaIntentResolver::Result.new(intent: plan.any? ? "action_plan" : "household_action", confidence: 1.0,
        continuation: false, resolved_message: message, needs_clarification: false, clarification: "",
        topic: { type: "household_setup", title: "Household setup" }, action: action, write_plan: plan, read_only_plan: {}, source: "deterministic")
    end

    def fixed_description
      return unless fixed_cents

      fixed = "Fixed essentials #{money(fixed_cents)} (rent #{money(amounts.fetch(:rent))} + utilities #{money(amounts.fetch(:utilities))})."
      groceries = "Groceries #{money(amounts[:groceries])} go under flexible spending." if amounts.key?(:groceries)
      [ fixed, groceries ].compact.join(" ")
    end

    def fixed_cents
      amounts && amounts.key?(:rent) && amounts.key?(:utilities) ? amounts.fetch(:rent) + amounts.fetch(:utilities) : nil
    end

    private

    attr_reader :message, :context

    def text
      message.gsub(MiaSetupGuide::SETUP_REQUEST, " ").squish
    end

    def amounts
      return @amounts if defined?(@amounts)

      readings = PATTERNS.transform_values { |pattern| text.scan(pattern).flatten }
      return @amounts = nil if readings.values.any?(&:many?)
      found = readings.filter_map { |key, matches| [ key, Money.chat_cents(matches.first) ] if matches.one? }.to_h
      return @amounts = nil if found.values.any? { |cents| cents > Money::MAX_AMOUNT_CENTS } || found.fetch(:rent, 0) + found.fetch(:utilities, 0) > Money::MAX_AMOUNT_CENTS
      @amounts = found.presence
    rescue ArgumentError
      @amounts = nil
    end

    def dollars(cents)
      Money.dollars(cents).to_s
    end

    def money(cents)
      ActiveSupport::NumberHelper.number_to_currency(Money.dollars(cents), precision: cents % 100 == 0 ? 0 : 2)
    end
  end
end
