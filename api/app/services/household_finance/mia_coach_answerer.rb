module HouseholdFinance
  class MiaCoachAnswerer
    AMOUNT_PATTERN = /\$\s*((?:\d{1,3}(?:,\d{3})+|\d{1,9})(?:\.\d{1,2})?)(?![\d,])/.freeze
    TRANSACTION_REPORT_PATTERN = /\b(?:i|we)\s+(?:spent|paid|charged|bought|withdrew)\b/i.freeze
    PURCHASE_INTENT_PATTERNS = [
      /\b(?:can|should|could|may)\s+(?:i|we)\b.*\b(?:buy|spend|purchase|afford|get|book|order)\b/i,
      /\bis it (?:okay|ok|safe|smart|in the cards)\b.*\b(?:to )?(?:buy|spend|purchase|afford|get|book|order)\b/i,
      /\b(?:i|we)\s+(?:want|need|have)\s+to\b.*\b(?:buy|spend|purchase|afford|get|book|order)\b/i
    ].freeze
    READINESS_PLAN_PATTERN = /\b(?:help\s+(?:me|us)\s+)?(?:create|make|build)?\s*(?:a\s+)?plan\b|\b(?:get|move)\s+(?:me|us|the household)?\s*(?:out of\s+)?(?:the\s+)?red\b|\b(?:yellow|green)\b.*\b(?:plan|readiness|baseline|runway|stabiliz|what do we need|next step)\b/i.freeze
    CAR_REGISTRATION_PATTERN = /\b(?:(?:car|vehicle|auto)\s+)?(?:registration|tags?)\b/i.freeze
    ESSENTIAL_PURCHASE_TERMS = /\b(?:groceries|grocery|food|medicine|medication|rent|mortgage|power|water|utilities|utility|insurance|gas|daycare|childcare|school|tuition|diapers|formula|doctor|medical|dental)\b/i.freeze
    SCREENSHOT_PURCHASE_TERMS = /\b(?:purse|bag|handbag)\b/i.freeze

    def initialize(household, message, annual_budget_manager: nil, reference_month: Date.current.month)
      @household = household
      @message = message.to_s.squish
      @annual_budget_manager = annual_budget_manager || AnnualBudgetManager.new(household, year: Date.current.year)
      @reference_month = reference_month.to_i.clamp(1, 12)
    end

    def call
      return nil if transaction_report?

      car_registration_answer || readiness_plan_answer || purchase_decision_answer
    end

    private

    attr_reader :household, :message, :annual_budget_manager, :reference_month

    def car_registration_answer
      return nil unless normalized_message.match?(CAR_REGISTRATION_PATTERN)
      return nil unless normalized_message.match?(/\b(?:can|could|should|afford|cover|pay|budget|plan|next month|due)\b/i)

      target_date = normalized_message.match?(/\bnext month\b/i) ? Date.current.next_month : Date.current
      target_manager = AnnualBudgetManager.new(household, year: target_date.year)
      target_plan = target_manager.plan_data
      month_index = target_date.month - 1
      expected_rows = active_rows(target_plan).select { |row| row.fetch(:stack_key) == "sinking_expected" }
      registration_row = expected_rows.find { |row| row.fetch(:name).match?(CAR_REGISTRATION_PATTERN) }
      expected_total = sum_month(expected_rows, month_index, :planned)
      amount_cents = amount_from_message_cents

      if registration_row
        month = registration_row.fetch(:months).fetch(month_index)
        planned_cents = dollars_to_cents(month.fetch(:planned))
        remaining_cents = dollars_to_cents(month.fetch(:remaining))
        return car_registration_with_category(target_plan, month_index, planned_cents, remaining_cents, amount_cents)
      end

      car_registration_without_category(target_plan, month_index, expected_total, amount_cents)
    end

    def car_registration_with_category(plan, month_index, planned_cents, remaining_cents, amount_cents)
      month_label = month_label(plan, month_index)
      if amount_cents&.positive?
        verdict = amount_cents <= remaining_cents ? "yes, it appears covered by the remaining car registration plan" : "not fully yet; it is #{money(amount_cents - remaining_cents)} over the remaining car registration plan"
        return "#{verdict.capitalize} for #{month_label}, based on your active annual plan. I can see #{money(planned_cents)} planned for car registration and #{money(remaining_cents)} remaining, while the registration amount you gave me is #{money(amount_cents)}. Pending drafts and future unlogged spending are not counted in that answer. Next CFO move: confirm the due date and keep this funded before approving discretionary wants."
      end

      "Car registration is an expected sinking-fund bill, not a random want. Based on your active annual plan for #{month_label}, I can see #{money(planned_cents)} planned and #{money(remaining_cents)} remaining for car registration, but I still need the actual amount and due date before I can say yes as a fact. Next CFO move: send me the registration amount and due date, then we will compare it to this category before touching discretionary money."
    end

    def car_registration_without_category(plan, month_index, expected_total_cents, amount_cents)
      month_label = month_label(plan, month_index)
      amount_line = amount_cents&.positive? ? " The amount you gave me is #{money(amount_cents)}, so that needs to be protected before discretionary wants." : " I do not have the registration amount or due date yet, so I cannot honestly say yes/no as a fact."
      "Car registration belongs in Sinking Fund — Expected; it should not be treated like a discretionary shoe or coffee decision. Based on your active annual plan for #{month_label}, I can see #{money(expected_total_cents)} planned across expected sinking funds, but I do not see a specific car registration line.#{amount_line} Next CFO move: add or rename a car registration category under Expected Sinking Fund, then set the monthly amount from the real due amount divided by the months left."
    end

    def readiness_plan_answer
      return nil unless normalized_message.match?(READINESS_PLAN_PATTERN)
      return nil if purchase_question?

      if snapshot.fetch(:monthly_income_cents).zero? || snapshot.fetch(:total_outflow_cents).zero?
        return "Based on what I can see, I do not have enough approved income and outflow data to build a real red-to-yellow-to-green plan yet. Add monthly income, fixed bills, debt minimums, liquid cash, and the main sinking-fund bills first so I am coaching from the household picture instead of guessing. Next CFO move: finish those profile numbers, then ask me for the yellow and green plan again."
      end

      surplus_cents = snapshot.fetch(:baseline_surplus_cents)
      yellow_gap = runway_gap_cents(yellow_runway_target_cents)
      green_gap = runway_gap_cents(green_runway_target_cents)
      transfer_cents = recommended_runway_transfer_cents(surplus_cents)
      cash_flow_line = surplus_cents.positive? ? "You have #{money(surplus_cents)} baseline surplus; I would route about #{money(transfer_cents)} of that toward runway before wants until yellow is protected." : "You are short by #{money(surplus_cents.abs)} each month, so yellow starts with cutting or reclassifying outflow before extra wants."

      "Yes — let’s make the plan from approved household numbers, not vibes. Right now readiness is #{snapshot.fetch(:readiness_label)}, runway is #{snapshot.fetch(:runway_months)} months, liquid assets are #{money(snapshot.fetch(:liquid_assets_cents))}, and baseline surplus is #{money(surplus_cents)} per month. Yellow means nonnegative monthly cash flow and about #{yellow_runway_months.round(1)} months of runway, so your current yellow gap is #{money(yellow_gap)}; green means #{target_runway_months.round(1)} months of runway with positive surplus, so the green gap is #{money(green_gap)}. #{cash_flow_line} Next CFO move: protect roof, food, utilities, debt minimums, and expected sinking funds first, then choose one discretionary hold for 30 days and send me any known upcoming bill amount so we can place it in the annual plan."
    end

    def purchase_decision_answer
      return nil unless purchase_question?
      return nil if normalized_message.match?(CAR_REGISTRATION_PATTERN)
      return nil if normalized_message.match?(SCREENSHOT_PURCHASE_TERMS)

      if normalized_message.match?(ESSENTIAL_PURCHASE_TERMS)
        return "This sounds like a baseline need, not a discretionary want. Based on the Household CFO priority order, protect roof, food, utilities, medical needs, and debt minimums before judging it like optional spending. I still need the amount and timing to say whether it fits this month’s cash flow. Next CFO move: send me the price and due date, then we will place it against the active plan."
      end

      item = purchase_item.presence || "that purchase"
      discretionary_remaining_cents = current_discretionary_remaining_cents
      safe_cents = snapshot.fetch(:safe_to_spend_cents)
      runway_status = "runway is #{snapshot.fetch(:runway_months)} months against a #{target_runway_months.round(1)} month target"
      verdict = if snapshot.fetch(:readiness_tone) == "green" && safe_cents.positive?
        "it may be okay only if the price fits inside true surplus and no sinking-fund bill is being skipped"
      else
        "I would not approve it yet unless it is a real need or already funded inside the plan"
      end

      "For #{item}, #{verdict}. Based on approved household numbers, readiness is #{snapshot.fetch(:readiness_label)}, safe-to-spend is #{money(safe_cents)}, #{runway_status}, and the active discretionary plan has about #{money(discretionary_remaining_cents)} remaining this month before future approvals. If this is required for work, school, or health, send me the amount and deadline so we can place it properly; if it is a want, put it on a 30-day list and fund it only after expected bills like registration are covered. Next CFO move: tell me the price and whether this is a need or a want."
    end

    def transaction_report?
      message.match?(TRANSACTION_REPORT_PATTERN) && message.match?(AMOUNT_PATTERN)
    end

    def purchase_question?
      PURCHASE_INTENT_PATTERNS.any? { |pattern| message.match?(pattern) }
    end

    def purchase_item
      match = normalized_message.match(/\b(?:buy|purchase|get|order|book|afford)\s+(?:these|this|the|a|an|some)?\s*([a-z0-9\s-]+?)(?:\s+(?:right now|today|this month|next month|for|because)|[?.!]|$)/i)
      return unless match

      match[1].to_s.squish.presence
    end

    def active_plan
      @active_plan ||= annual_budget_manager.plan_data
    end

    def current_discretionary_remaining_cents
      month_index = reference_month - 1
      rows = active_rows(active_plan).select { |row| row.fetch(:stack_key) == "discretionary" }
      sum_month(rows, month_index, :remaining)
    end

    def active_rows(plan)
      plan.fetch(:rows).select { |row| row.fetch(:active, true) }
    end

    def sum_month(rows, month_index, key)
      rows.sum { |row| dollars_to_cents(row.fetch(:months).fetch(month_index).fetch(key)) }
    end

    def amount_from_message_cents
      match = message.match(AMOUNT_PATTERN)
      return unless match

      Money.cents(match[1].delete(","))
    end

    def snapshot
      @snapshot ||= SnapshotBuilder.new(household).call
    end

    def target_runway_months
      snapshot.fetch(:target_runway_months).to_f
    end

    def yellow_runway_months
      target_runway_months / 2.0
    end

    def yellow_runway_target_cents
      (snapshot.fetch(:total_outflow_cents) * yellow_runway_months).round
    end

    def green_runway_target_cents
      (snapshot.fetch(:total_outflow_cents) * target_runway_months).round
    end

    def runway_gap_cents(target_cents)
      [ target_cents - snapshot.fetch(:liquid_assets_cents), 0 ].max
    end

    def recommended_runway_transfer_cents(surplus_cents)
      return 0 unless surplus_cents.positive?

      [ (surplus_cents * 0.6).round, surplus_cents ].min
    end

    def month_label(plan, month_index)
      "#{plan.fetch(:months).fetch(month_index).fetch(:label)} #{plan.fetch(:year)}"
    end

    def normalized_message
      @normalized_message ||= message.downcase.gsub(/[^a-z0-9\s$.-]/, " ").squish
    end

    def dollars_to_cents(value)
      (value.to_f * 100).round
    end

    def money(cents)
      ActiveSupport::NumberHelper.number_to_currency(Money.dollars(cents), precision: 0)
    end
  end
end
