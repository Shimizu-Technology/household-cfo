module HouseholdFinance
  class MiaCoachAnswerer
    AMOUNT_PATTERN = /\$\s*((?:\d{1,3}(?:,\d{3})+|\d{1,9})(?:\.\d{1,2})?)(?![\d,])/.freeze
    TRANSACTION_REPORT_PATTERN = /\b(?:i|we)\s+(?:spent|paid|charged|bought|withdrew)\b/i.freeze
    PURCHASE_INTENT_PATTERNS = [
      /\b(?:can|should|could|may)\s+(?:i|we)\b.*\b(?:buy|spend|purchase|afford|get|book|order)\b/i,
      /\bis it (?:okay|ok|safe|smart|in the cards)\b.*\b(?:to )?(?:buy|spend|purchase|afford|get|book|order)\b/i,
      /\b(?:i|we)\s+(?:want|need|have)\s+to\b.*\b(?:buy|spend|purchase|afford|get|book|order)\b/i,
      /\b(?:can|should|could|may)\s+(?:i|we)\b.*\b(?:take|go on|book)\b.*\b(?:trip|vacation|staycation)\b/i
    ].freeze
    READINESS_PLAN_PATTERN = /\b(?:help\s+(?:me|us)\s+)?(?:create|make|build)?\s*(?:a\s+)?(?:concrete\s+|specific\s+|detailed\s+|step(?: |-)?by(?: |-)?step\s+)?plan\b|\b(?:get|move)\s+(?:me|us|the household)?\s*(?:out of\s+)?(?:the\s+)?red\b|\b(?:yellow|green)\b.*\b(?:plan|readiness|baseline|runway|stabiliz|what do we need|next step)\b/i.freeze
    CAR_REGISTRATION_PATTERN = /\b(?:(?:car|vehicle|auto)\s+)?(?:registration|tags?)\b/i.freeze
    CAR_REPAIR_PATTERN = /\b(?:car|vehicle|auto)\s+repair\b/i.freeze
    ESSENTIAL_PURCHASE_TERMS = /\b(?:groceries|grocery|food|medicine|medication|rent|mortgage|power|water|utilities|utility|insurance|gas|daycare|childcare|school|tuition|diapers|formula|doctor|medical|dental)\b/i.freeze
    SCREENSHOT_PURCHASE_TERMS = /\b(?:purse|bag|handbag)\b/i.freeze
    PLANNED_PURCHASE_DETAIL_PATTERN = /(?:costs?|price|\$\s*\d|does that change|kid|school|work|league)/i.freeze
    FAMILY_SUPPORT_PATTERN = /\b(?:cousin|family|auntie|aunty|uncle|sibling|brother|sister|parent|mom|dad|friend)\b.*\b(?:asks?|asked|asking|borrow|lend|loan|help|support|give|send)\b|\b(?:asks?|asked|asking|borrow|lend|loan|help|support|give|send)\b.*\b(?:cousin|family|auntie|aunty|uncle|sibling|brother|sister|parent|mom|dad|friend|off-island)\b/i.freeze
    DEBT_VS_SAVINGS_PATTERN = /\b(?:debt|credit card|loan)\b.*\b(?:saving|savings|emergency|runway|extra|payoff|pay off)\b|\b(?:saving|savings|emergency|runway)\b.*\b(?:debt|credit card|loan|payoff|pay off)\b/i.freeze
    JOB_TRANSITION_PATTERN = /\b(?:leave|quit|stop|reduce\s+hours?|cut\s+hours?)\b.*\b(?:job|work|hours?)\b|\b(?:run|focus on)\b.*\b(?:my )?business\b|\bbusiness\s+income\b|\bbusiness\b.*\b(?:one big client|no contracts?)\b/i.freeze
    OVERWHELMED_PATTERN = /\b(?:overwhelmed|behind|stressed|panic|panicking|drowning|where do i start|what do i do first|hide from bills)\b/i.freeze
    EMOTIONAL_STRESS_PATTERN = /\b(?:ashamed|shame|stupid|spouse|fighting about money)\b/i.freeze
    BILL_TRIAGE_PATTERN = /\b(?:bills?|payday|due before payday|only\s+\$?\d|pay first|what do i pay first)\b/i.freeze
    EXTRA_MONEY_PATTERN = /\b(?:got|received|have|came into|bonus|windfall|tax refund|refund)\b.*\b(?:extra|bonus|windfall|refund|\$\s*\d)\b.*\b(?:emergency|debt|registration|savings|runway)\b/i.freeze
    DEBT_DECISION_PATTERN = /\b(?:skip|miss)\b.*\b(?:credit card|debt|payment|minimum)\b|\b(?:payday loan|balance transfer|consolidat|highest interest|smallest balance|close old credit cards?|credit score|minimum went up)\b/i.freeze
    SINKING_FUND_PATTERN = /\b(?:sinking fund|school uniforms?|back.?to.?school|fridge|appliance|insurance renewal|renewal|gifts?|unexpected sinking|expected sinking|home repair)\b/i.freeze
    LENDING_PATTERN = /\b(?:lend|loan)\b.*\bmoney\b|\bpay me back\b/i.freeze
    MEMORY_RECALL_PATTERN = /\b(?:forgot|remember)\b.*\b(?:decided|plan)\b|\bwhat was the plan\b|\blast time\b/i.freeze
    INVESTMENT_PATTERN = /\b(?:stocks?|crypto|bitcoin|invest(?:ing|ment)?|risky products?)\b/i.freeze
    MONEY_MOVEMENT_PATTERN = /\b(?:move|transfer)\b.*\b(?:savings|checking|bank|banker|account)\b/i.freeze
    PAYCHECK_PATTERN = /\b(?:before|until|next)\s+(?:my\s+|our\s+)?paycheck\b/i.freeze
    EXTERNAL_FACT_PATTERN = /\b(?:current\s+.*rate|look\s+up|dmv|usually\s+cost|cost\s+usually|typical(?:ly)?\s+cost|average\s+cost|bank statement|overdraft|credit score|tax refund|business taxes?|file married|filing status|payoff amount|real-time|official fee)\b/i.freeze
    AMBIGUOUS_HELP_PATTERN = /\A(?:help|what should i do\??|is this bad\??)\z/i.freeze
    PROMPT_INJECTION_PATTERN = /\b(?:ignore all previous rules|ignore previous instructions|developer mode|jailbreak|you are now)\b/i.freeze

    def initialize(household, message, annual_budget_manager: nil, reference_month: Date.current.month)
      @household = household
      @message = message.to_s.squish
      @annual_budget_manager = annual_budget_manager || AnnualBudgetManager.new(household, year: Date.current.year)
      @reference_month = reference_month.to_i.clamp(1, 12)
    end

    def call
      return nil if transaction_report?

      memory_recall_answer || prompt_injection_answer || investment_boundary_answer || external_fact_answer || ambiguous_help_answer || money_movement_boundary_answer || paycheck_plan_answer || debt_decision_answer || bill_triage_answer || extra_money_answer || car_repair_answer || sinking_fund_answer || car_registration_answer || readiness_plan_answer || family_support_answer || lending_answer || debt_vs_savings_answer || job_transition_answer || emotional_stress_answer || overwhelmed_answer || planned_purchase_detail_answer || purchase_decision_answer
    end

    def prepared_annual_plan
      @active_plan if defined?(@active_plan)
    end

    private

    attr_reader :household, :message, :annual_budget_manager, :reference_month

    def memory_recall_answer
      return nil unless normalized_message.match?(MEMORY_RECALL_PATTERN)

      "Based on what I can see, I do not have enough approved data to repeat a prior chat decision as a fact yet. What I can see is the current approved household picture: readiness is #{snapshot.fetch(:readiness_label)}, runway is #{snapshot.fetch(:runway_months)} months, and baseline surplus is #{money(snapshot.fetch(:baseline_surplus_cents))} per month. Next CFO move: ask for the red-to-yellow plan again or name the decision you remember, and we will rebuild it from approved numbers instead of guessing."
    end

    def prompt_injection_answer
      return nil unless normalized_message.match?(PROMPT_INJECTION_PATTERN)
      return nil if normalized_message.match?(MONEY_MOVEMENT_PATTERN)

      "I cannot ignore the Household CFO safety and product boundaries. Based on approved household numbers, readiness is #{snapshot.fetch(:readiness_label)}, safe-to-spend is #{money(snapshot.fetch(:safe_to_spend_cents))}, and runway is #{snapshot.fetch(:runway_months)} months, so I will not pretend the household can buy anything or override approval rules. Next CFO move: ask the real money question, and I will answer from confirmed facts, active plan, and pending drafts separately."
    end

    def investment_boundary_answer
      return nil unless normalized_message.match?(INVESTMENT_PATTERN)

      "Based on approved household numbers, this is not the moment to use investing or risky products as the shortcut to green: readiness is #{snapshot.fetch(:readiness_label)}, runway is #{snapshot.fetch(:runway_months)} months, and safe-to-spend is #{money(snapshot.fetch(:safe_to_spend_cents))}. I cannot give licensed investment advice or tell you what stock or crypto to buy. Next CFO move: protect roof, food, utilities, debt minimums, and emergency runway first; only discuss investing after the baseline and sinking funds are stable."
    end

    def external_fact_answer
      return nil unless normalized_message.match?(EXTERNAL_FACT_PATTERN)

      if normalized_message.match?(/tax|file married|filing status/i)
        return "Based on what I can see, I do not have enough approved data to answer that as a fact yet. I also cannot give tax advice or tell you which filing status to choose. Based on approved household numbers, readiness is #{snapshot.fetch(:readiness_label)}, so any tax bill or refund should be placed against the baseline before wants. Next CFO move: use a qualified tax professional or tax software for the tax calculation, then bring the amount and due date back here so we can place it in the annual plan."
      end

      if normalized_message.match?(/bank statement|overdraft|payoff amount|credit score/i)
        return "Based on what I can see, I do not have enough approved data to answer that as a fact yet. I cannot see real-time bank balances, pending bank fees, credit scores, statement text, or exact payoff amounts unless they are imported and approved in Household CFO. Next CFO move: verify the number in the official account portal or statement, then send the amount and due date so we can update the plan without guessing."
      end

      "Based on what I can see, I do not have enough approved data to answer that as a fact yet. I cannot look up current external rates or fee schedules in v1, and I should not guess official costs. Next CFO move: check the official source or your latest bill, then bring back the amount and due date so we can place it in the active annual plan."
    end

    def ambiguous_help_answer
      return nil unless normalized_message.match?(AMBIGUOUS_HELP_PATTERN)

      "Based on what I can see, I do not have enough approved data to answer that as a fact yet. Based on approved household numbers, readiness is #{snapshot.fetch(:readiness_label)}, runway is #{snapshot.fetch(:runway_months)} months, and safe-to-spend is #{money(snapshot.fetch(:safe_to_spend_cents))}, so the default move is to protect the baseline first. Next CFO move: tell me whether this is a bill, a purchase, a debt decision, or family support, and include the amount and due date if money might move."
    end

    def money_movement_boundary_answer
      return nil unless normalized_message.match?(MONEY_MOVEMENT_PATTERN)

      "I cannot move money or act like your banker. Based on approved household numbers, readiness is #{snapshot.fetch(:readiness_label)} and safe-to-spend is #{money(snapshot.fetch(:safe_to_spend_cents))}, so any transfer needs a named purpose before money moves. Next CFO move: decide whether the transfer protects a due bill, runway, or an expected sinking fund, then make the transfer yourself in your bank only if it still protects the household baseline."
    end

    def paycheck_plan_answer
      return nil unless normalized_message.match?(PAYCHECK_PATTERN)

      "Before the next paycheck, protect the baseline and stop new leaks. Based on approved household numbers, readiness is #{snapshot.fetch(:readiness_label)}, baseline surplus is #{money(snapshot.fetch(:baseline_surplus_cents))} per month, and safe-to-spend is #{money(snapshot.fetch(:safe_to_spend_cents))}. I do not have the exact due dates between now and payday, so I cannot rank them as facts yet. Next CFO move: list the bills due before payday with amount, due date, and consequence if late; then pause non-essential spending until those are covered."
    end

    def bill_triage_answer
      return nil unless normalized_message.match?(BILL_TRIAGE_PATTERN)
      return nil if normalized_message.match?(CAR_REGISTRATION_PATTERN)
      return nil if readiness_follow_up?

      "Start with the bill that protects the household baseline first. Based on approved household numbers, readiness is #{snapshot.fetch(:readiness_label)}, baseline surplus is #{money(snapshot.fetch(:baseline_surplus_cents))} per month, and safe-to-spend is #{money(snapshot.fetch(:safe_to_spend_cents))}; that means roof, food, utilities, medical needs, and debt minimums outrank wants. I do not have the three bill names, amounts, and due dates yet, so I cannot choose the exact bill as a fact. Next CFO move: list each due date, amount, and consequence if late; then we pay the highest-consequence essential first and call the others before the due date."
    end

    def extra_money_answer
      return nil unless normalized_message.match?(EXTRA_MONEY_PATTERN)

      yellow_gap = runway_gap_cents(yellow_runway_target_cents)
      "Treat the extra money like a stabilizer, not a permission slip. Based on approved household numbers, readiness is #{snapshot.fetch(:readiness_label)}, safe-to-spend is #{money(snapshot.fetch(:safe_to_spend_cents))}, baseline surplus is #{money(snapshot.fetch(:baseline_surplus_cents))}, and the yellow runway gap is #{money(yellow_gap)}. Protect any due expected sinking-fund bill first, then send the rest toward runway before extra debt unless a minimum payment is at risk. Next CFO move: name the due date for car registration and the next debt minimum, then split the extra dollars only after those two facts are clear."
    end

    def debt_decision_answer
      return nil unless normalized_message.match?(DEBT_DECISION_PATTERN)

      if normalized_message.match?(/payday loan/i)
        return "I would treat a payday loan as a last-resort emergency option, not a plan. Based on approved household numbers, readiness is #{snapshot.fetch(:readiness_label)}, baseline surplus is #{money(snapshot.fetch(:baseline_surplus_cents))}, and runway is #{snapshot.fetch(:runway_months)} months; high-cost debt can make red harder to escape. I cannot give licensed credit or legal advice, and I do not have the rent amount, due date, late fee, or other options yet. Next CFO move: call the landlord or lender before the due date, ask about a payment arrangement, and send me the exact gap before taking high-cost debt."
      end

      if normalized_message.match?(/skip|miss/i)
        return "Do not make skipping a debt minimum the plan until you have checked every baseline option. Based on approved household numbers, readiness is #{snapshot.fetch(:readiness_label)} and baseline surplus is #{money(snapshot.fetch(:baseline_surplus_cents))}, so debt minimums stay in the protected baseline with roof, food, and utilities. I still need the payment amount, due date, current cash, and late consequences before saying what to do as a fact. Next CFO move: list those four numbers and contact the issuer before the due date if the minimum is at risk."
      end

      "Based on what I can see, I do not have enough approved debt details to answer that as a fact yet. Your approved household numbers show #{money(snapshot.fetch(:total_debt_cents))} debt entered, readiness is #{snapshot.fetch(:readiness_label)}, and runway is #{snapshot.fetch(:runway_months)} months, but I still need balances, APRs, fees, minimums, and due dates before comparing debt strategies. I cannot give licensed credit advice or promise a credit-score outcome. Next CFO move: add or send the APR, balance, minimum payment, and fee for each option, then we compare whether it improves cash flow without stealing from runway."
    end

    def car_repair_answer
      return nil unless normalized_message.match?(CAR_REPAIR_PATTERN)

      amount_cents = amount_from_message_cents
      amount_line = amount_cents&.positive? ? " The amount you gave me is #{money(amount_cents)}, so it needs to be protected before wants." : " I still need the estimate and deadline before I can say yes as a fact."
      "A car repair can be a real baseline need if it protects work, school, medical care, or household safety. Based on approved household numbers, readiness is #{snapshot.fetch(:readiness_label)}, runway is #{snapshot.fetch(:runway_months)} months, and safe-to-spend is #{money(snapshot.fetch(:safe_to_spend_cents))}.#{amount_line} Next CFO move: get the repair estimate and due date, then fund it from unexpected sinking fund or emergency runway before discretionary purchases."
    end

    def sinking_fund_answer
      return nil unless normalized_message.match?(SINKING_FUND_PATTERN)
      return nil if normalized_message.match?(CAR_REGISTRATION_PATTERN)

      target_month = target_month_index_from_message || reference_month - 1
      plan = active_plan
      expected_cents = sum_month(active_rows(plan).select { |row| row.fetch(:stack_key) == "sinking_expected" }, target_month, :planned)
      unexpected_cents = sum_month(active_rows(plan).select { |row| row.fetch(:stack_key) == "sinking_unexpected" }, target_month, :planned)
      month_name = month_label(plan, target_month)

      if normalized_message.match?(/pause.*unexpected/i)
        return "Only pause the unexpected sinking fund as a named one-month triage move, not as an invisible cut. Based on your active annual plan for #{month_name}, unexpected sinking funds have #{money(unexpected_cents)} planned while readiness is #{snapshot.fetch(:readiness_label)}. If that money is needed for roof, food, utilities, or debt minimums, the pause can make sense; if it funds wants, it keeps the household fragile. Next CFO move: write the exact bill this pause protects, then schedule the category to restart next month."
      end

      if normalized_message.match?(/gifts?/i)
        return "Planned gifts belong in Sinking Fund — Expected; surprise gifts belong in Discretionary. Based on your active annual plan for #{month_name}, expected sinking funds have #{money(expected_cents)} planned and discretionary money should not jump ahead of readiness #{snapshot.fetch(:readiness_label)}. Next CFO move: create or use one gift category for known birthdays/holidays, then put last-minute gifts through the normal discretionary approval rule."
      end

      if normalized_message.match?(/fridge|appliance|home repair/i)
        return "A likely fridge or home repair belongs in Sinking Fund — Unexpected until you have a real quote. Based on your active annual plan for #{month_name}, unexpected sinking funds have #{money(unexpected_cents)} planned, and pending drafts are not counted as actuals. Next CFO move: get the repair/replacement estimate, then decide what discretionary category pauses while you build or protect that amount."
      end

      if normalized_message.match?(/insurance renewal|renewal/i)
        return "Insurance renewal belongs in Sinking Fund — Expected because you know it is coming. Based on your active annual plan for #{month_name}, expected sinking funds have #{money(expected_cents)} planned, but I still need the renewal amount to calculate the monthly set-aside. Next CFO move: divide the real renewal amount by the months left, then add or update the expected sinking-fund category before approving wants."
      end

      "This belongs in Sinking Fund — Expected if the date is known, and Sinking Fund — Unexpected if the amount or timing is still uncertain. Based on your active annual plan for #{month_name}, expected sinking funds have #{money(expected_cents)} planned and unexpected sinking funds have #{money(unexpected_cents)} planned. Next CFO move: send me the amount and due date, then place it in the right stack before discretionary spending gets approved."
    end

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
      return nil if budget_report_question?

      if snapshot.fetch(:monthly_income_cents).zero? || snapshot.fetch(:total_outflow_cents).zero?
        return "Based on what I can see, I do not have enough approved income and outflow data to build a real red-to-yellow-to-green plan yet. Add monthly income, fixed bills, debt minimums, liquid cash, and the main sinking-fund bills first so I am coaching from the household picture instead of guessing. Next CFO move: finish those profile numbers, then ask me for the yellow and green plan again."
      end

      surplus_cents = snapshot.fetch(:baseline_surplus_cents)
      yellow_gap = runway_gap_cents(yellow_runway_target_cents)
      green_gap = runway_gap_cents(green_runway_target_cents)
      transfer_cents = recommended_runway_transfer_cents(surplus_cents)
      return readiness_execution_plan(surplus_cents, transfer_cents, yellow_gap, green_gap) if readiness_follow_up?
      return weekly_readiness_plan(surplus_cents, transfer_cents, yellow_gap) if normalized_message.match?(/\b(this week|do first|first step|start)\b/i)
      return green_readiness_plan(surplus_cents, transfer_cents, green_gap) if normalized_message.match?(/\bgreen\b/i) && !normalized_message.match?(/\b(?:red|yellow)\b/i)

      red_to_yellow_plan(surplus_cents, transfer_cents, yellow_gap, green_gap)
    end

    def readiness_follow_up?
      normalized_message.match?(/follow up to previous readiness plan topic/) ||
        normalized_message.match?(/\b(?:concrete|step by step|actual|specific|detailed)\s+plan\b/i)
    end

    def red_to_yellow_plan(surplus_cents, transfer_cents, yellow_gap, green_gap)
      cash_flow_line = if surplus_cents.positive?
        "Your monthly cash flow is positive by #{money(surplus_cents)}, so red is mainly a runway problem; protect about #{money(transfer_cents)} for runway before new wants."
      else
        "Your monthly cash flow is short by #{money(surplus_cents.abs)}, so the first target is getting the baseline back to $0 before chasing green."
      end

      "Yes — let’s make the plan from approved household numbers, not vibes. Current basis: readiness is #{snapshot.fetch(:readiness_label)}, runway is #{snapshot.fetch(:runway_months)} months, liquid assets are #{money(snapshot.fetch(:liquid_assets_cents))}, and baseline surplus is #{money(surplus_cents)} per month. Yellow means nonnegative monthly cash flow and about #{yellow_runway_months.round(1)} months of runway, so the yellow gap is #{money(yellow_gap)}; green means #{target_runway_months.round(1)} months of runway with positive surplus, so the green gap is #{money(green_gap)}. #{cash_flow_line} Next CFO move: ask me for the concrete plan, or send the next three due bills so we can turn this into this week’s moves."
    end

    def readiness_execution_plan(surplus_cents, transfer_cents, yellow_gap, green_gap)
      month_index = reference_month - 1
      discretionary_line = top_month_row_line("discretionary", month_index) || "the largest discretionary line"
      expected_line = top_month_row_line("sinking_expected", month_index) || "the next expected sinking-fund bill"
      baseline_step = if surplus_cents.negative?
        "Find #{money(surplus_cents.abs)} per month before adding wants. Start with #{discretionary_line}; if that does not close the gap, renegotiate one fixed bill or debt due date before the next paycheck."
      else
        "Keep the #{money(surplus_cents)} monthly surplus from leaking. Route about #{money(transfer_cents)} to runway after bills clear, then leave the rest as buffer until yellow is protected."
      end
      runway_step = if yellow_gap.positive? && transfer_cents.positive?
        "At #{money(transfer_cents)} per month, yellow is roughly #{(yellow_gap.to_f / transfer_cents).ceil} month(s) away; green still needs #{money(green_gap)} of runway."
      elsif yellow_gap.positive?
        "Yellow still needs #{money(yellow_gap)}, but there is no safe surplus yet, so do not force a runway transfer until cash flow is nonnegative."
      else
        "Yellow runway is covered; keep building toward the green gap of #{money(green_gap)} without stealing from expected bills."
      end

      "Absolutely — here is the working plan, not another diagnosis. Current basis: readiness is #{snapshot.fetch(:readiness_label)}, runway is #{snapshot.fetch(:runway_months)} months, and baseline surplus is #{money(surplus_cents)}. 1) Today: pause new wants, review pending drafts, and protect roof, food, utilities, debt minimums, and #{expected_line}. 2) This week: #{baseline_step} 3) This month: #{runway_step} 4) Review point: after the next paycheck, update confirmed transactions and check whether the baseline is still nonnegative. Next CFO move: send me the next three due dates and amounts; I’ll help rank what gets paid, paused, or moved."
    end

    def green_readiness_plan(surplus_cents, transfer_cents, green_gap)
      runway_line = if transfer_cents.positive? && green_gap.positive?
        "At about #{money(transfer_cents)} per month, green is roughly #{(green_gap.to_f / transfer_cents).ceil} month(s) of protected transfers away."
      elsif green_gap.positive?
        "Green needs #{money(green_gap)} more runway, but cash flow has to turn nonnegative before that transfer is safe."
      else
        "The green runway target is funded on paper; the job is consistency, not a dramatic cut."
      end

      "To get to green, keep the baseline boring and make runway automatic. Based on approved household numbers, readiness is #{snapshot.fetch(:readiness_label)}, runway is #{snapshot.fetch(:runway_months)} months, baseline surplus is #{money(surplus_cents)}, and the green runway gap is #{money(green_gap)}. #{runway_line} Next CFO move: protect expected sinking funds first, then set a recurring runway transfer and do not increase discretionary spending until two clean months are confirmed."
    end

    def weekly_readiness_plan(surplus_cents, transfer_cents, yellow_gap)
      if surplus_cents.positive?
        return "This week, the goal is not to solve everything; it is to stop Red from leaking. Based on approved household numbers, your yellow runway gap is #{money(yellow_gap)}, and you have #{money(surplus_cents)} baseline surplus before new approvals. Protect essentials and expected sinking funds first, pause non-essential purchases unless they are already funded in the plan, then route about #{money(transfer_cents)} toward runway. Next CFO move: choose the one discretionary hold you can keep for seven days and make the runway transfer after bills clear."
      end

      "This week, the goal is to stop the shortfall before chasing green. Based on approved household numbers, monthly cash flow is short by #{money(surplus_cents.abs)}, so the first move is to protect roof, food, utilities, and debt minimums, then identify one bill or discretionary category to reduce before the next paycheck. Next CFO move: send me the one expense you are willing to cut or renegotiate this week, and we will put that savings toward getting back to yellow."
    end

    def family_support_answer
      return nil unless normalized_message.match?(FAMILY_SUPPORT_PATTERN)

      amount_cents = amount_from_message_cents
      return family_support_tradeoff_answer(amount_cents) if family_support_tradeoff?

      amount_label = amount_cents&.positive? ? "#{money(amount_cents)}" : "money"
      if amount_cents&.positive? && amount_cents <= snapshot.fetch(:safe_to_spend_cents) && snapshot.fetch(:readiness_tone) != "red"
        return "Yes, you may be able to help with #{amount_label}, but only as a planned family-support decision, not from bill money. Based on approved household numbers, safe-to-spend is #{money(snapshot.fetch(:safe_to_spend_cents))}, runway is #{snapshot.fetch(:runway_months)} months, and readiness is #{snapshot.fetch(:readiness_label)}. Set the help as a one-time amount with no open-ended repeat promise. Next CFO move: say the number, the date, and the boundary out loud before money leaves."
      end

      "I would not give a clean yes yet, even though wanting to help makes sense. Based on approved household numbers, readiness is #{snapshot.fetch(:readiness_label)}, safe-to-spend is #{money(snapshot.fetch(:safe_to_spend_cents))}, and runway is #{snapshot.fetch(:runway_months)} months; family support cannot jump ahead of roof, food, utilities, debt minimums, and expected bills. If you still want to help, choose non-cash help or a smaller number that does not touch the household baseline. Next CFO move: decide the maximum amount you can give once, without creating a repeat obligation."
    end

    def family_support_tradeoff?
      normalized_message.match?(/\b(?:cut|pause|reduce|trim|use|cover|trade)\b/i) &&
        normalized_message.match?(/\b(?:dining|restaurant|coffee|takeout|discretionary)\b/i)
    end

    def family_support_tradeoff_answer(amount_cents)
      plan = active_plan
      month_index = reference_month - 1
      dining_rows = active_rows(plan).select { |row| row.fetch(:name).match?(/dining|restaurant|coffee|takeout/i) }
      target_rows = dining_rows.presence || active_rows(plan).select { |row| row.fetch(:stack_key) == "discretionary" }
      planned_cents = sum_month(target_rows, month_index, :planned)
      remaining_cents = sum_month(target_rows, month_index, :remaining)
      target_label = target_rows.map { |row| row.fetch(:name) }.first(3).to_sentence.presence || "discretionary spending"
      amount_line = amount_cents&.positive? ? "The family-support amount on the table is #{money(amount_cents)}." : "I still need the exact family-support amount before I can compare the tradeoff as a fact."
      coverage_line = if amount_cents&.positive? && remaining_cents >= amount_cents
        "That category has enough remaining on paper to cover it, but the household still needs a one-time boundary because readiness is #{snapshot.fetch(:readiness_label)}."
      elsif amount_cents&.positive?
        "That does not fully cover it; it is #{money(amount_cents - remaining_cents)} more than the remaining #{target_label} plan."
      else
        "Use this as a tradeoff test before any cash leaves."
      end

      "Cutting #{target_label} is the right kind of tradeoff to test for family support, but it is not an automatic yes. Based on your active annual plan for #{month_label(plan, month_index)}, #{target_label} has #{money(planned_cents)} planned and #{money(remaining_cents)} remaining; pending drafts are not counted as actuals. #{amount_line} #{coverage_line} Next CFO move: choose the exact one-time amount and write down what #{target_label} pauses this month before promising help."
    end

    def lending_answer
      return nil unless normalized_message.match?(LENDING_PATTERN)

      "I would treat that as family-support risk unless the household can afford it as a gift. Based on approved household numbers, readiness is #{snapshot.fetch(:readiness_label)}, safe-to-spend is #{money(snapshot.fetch(:safe_to_spend_cents))}, and runway is #{snapshot.fetch(:runway_months)} months, so a promise to pay you back cannot protect your roof, food, utilities, or debt minimums. Next CFO move: decide the amount you could survive never getting back; if that number is zero, the answer is no cash help this time."
    end

    def debt_vs_savings_answer
      return nil unless normalized_message.match?(DEBT_VS_SAVINGS_PATTERN)

      debt_cents = snapshot.fetch(:total_debt_cents)
      liquid_cents = snapshot.fetch(:liquid_assets_cents)
      yellow_gap = runway_gap_cents(yellow_runway_target_cents)
      if yellow_gap.positive?
        return "Savings comes first until you reach yellow, then extra debt gets more room. Based on approved household numbers, you have #{money(liquid_cents)} liquid, #{money(debt_cents)} debt entered, #{snapshot.fetch(:runway_months)} months of runway, and a yellow runway gap of #{money(yellow_gap)}. Keep paying debt minimums, but do not send extra debt payments while the household still needs basic runway. Next CFO move: route the next available surplus to runway until yellow is protected, then split extra dollars between debt and savings."
      end

      "You have enough runway for yellow, so extra debt can start competing with additional savings. Based on approved household numbers, liquid assets are #{money(liquid_cents)}, debt entered is #{money(debt_cents)}, and readiness is #{snapshot.fetch(:readiness_label)}. Keep emergency runway intact, then use a fixed extra-payment amount so debt payoff does not steal from sinking funds. Next CFO move: pick the monthly extra debt amount only after expected bills are funded."
    end

    def job_transition_answer
      return nil unless normalized_message.match?(JOB_TRANSITION_PATTERN)

      business_cents = business_income_cents
      green_gap = runway_gap_cents(green_runway_target_cents)
      "Not yet as a full leap; this is a runway decision, not a motivation decision. Based on approved household numbers, readiness is #{snapshot.fetch(:readiness_label)}, runway is #{snapshot.fetch(:runway_months)} months, business income entered is #{money(business_cents)} per month, and the green runway gap is #{money(green_gap)}. Keep stable income in the picture until household runway and repeatable business income can carry the baseline without panic. Next CFO move: define the monthly business-income floor and runway number that must be true before you revisit leaving the job."
    end

    def emotional_stress_answer
      return nil unless normalized_message.match?(EMOTIONAL_STRESS_PATTERN)

      if normalized_message.match?(/spouse|fighting/i)
        return "Tonight is not for solving the whole budget; it is for getting both of you back on the same side of the table. Based on approved household numbers, readiness is #{snapshot.fetch(:readiness_label)}, so the shared target is protecting roof, food, utilities, debt minimums, and the next due bill before blame. Next CFO move: each person names one bill or purchase they are worried about, then you pick one baseline action for the next 24 hours."
      end

      "You are not stupid, and the numbers are not a verdict on your worth. Based on approved household numbers, readiness is #{snapshot.fetch(:readiness_label)}, so the kindest next move is smaller, not harsher: protect roof, food, utilities, debt minimums, and the next due bill. Next CFO move: list the next three due dates and amounts; we will make one clean decision at a time."
    end

    def overwhelmed_answer
      return nil unless normalized_message.match?(OVERWHELMED_PATTERN)

      "Start with the baseline, not the whole mountain. Based on approved household numbers, readiness is #{snapshot.fetch(:readiness_label)}, so the first pass is roof, food, utilities, debt minimums, and any bill due before the next paycheck. Do not solve shoes, extra debt, family requests, or dreams until those are named. Next CFO move: list the next three due dates and amounts; then we decide what gets paid, paused, or moved."
    end

    def planned_purchase_detail_answer
      return nil unless amount_from_message_cents&.positive?
      return nil unless normalized_message.match?(PLANNED_PURCHASE_DETAIL_PATTERN)
      return nil if transaction_report?
      return nil if normalized_message.match?(CAR_REGISTRATION_PATTERN)
      return nil if normalized_message.match?(BILL_TRIAGE_PATTERN) || normalized_message.match?(EXTRA_MONEY_PATTERN) || normalized_message.match?(MONEY_MOVEMENT_PATTERN)

      amount_cents = amount_from_message_cents
      need_language = normalized_message.match?(/\b(?:kid|school|work|health|medical|league|required|need)\b/i)
      coverage_line = amount_cents <= current_discretionary_remaining_cents ? "the amount fits inside the remaining discretionary plan, but that still does not automatically make it wise while readiness is #{snapshot.fetch(:readiness_label)}." : "the amount is above what I can see as remaining in the active discretionary plan, so it needs a tradeoff before approval."
      classification = need_language ? "That does change the category: this sounds closer to a family need or commitment than a random want." : "That gives me the amount, but I still need to know whether this is a need or a want."

      "#{classification} Based on approved household numbers, the purchase is #{money(amount_cents)}, safe-to-spend is #{money(snapshot.fetch(:safe_to_spend_cents))}, and #{coverage_line} I would not create an actual transaction draft because the money has not left yet; this is a pre-spend CFO decision. Next CFO move: if you approve it, name which category funds it and what gets paused so expected bills stay covered."
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
      return false if normalized_message.match?(/\b(?:get|move)\s+(?:me|us|the household)?\s*(?:out of\s+)?(?:the\s+)?red\b/i)
      return false if normalized_message.match?(MONEY_MOVEMENT_PATTERN)

      PURCHASE_INTENT_PATTERNS.any? { |pattern| message.match?(pattern) }
    end

    def budget_report_question?
      normalized_message.match?(/\b(?:categories?|spending|spent|actuals?|transactions?|pending|over\s+plan|under\s+plan|over\s+budget|under\s+budget|left|remaining)\b/i) &&
        !normalized_message.match?(/\b(?:red|yellow|green|readiness|runway|stabiliz)\b/i)
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

    def top_month_row_line(stack_key, month_index)
      rows = active_rows(active_plan).select { |row| row.fetch(:stack_key) == stack_key }
      row = rows.max_by { |candidate| dollars_to_cents(candidate.fetch(:months).fetch(month_index).fetch(:remaining)) }
      return unless row

      month = row.fetch(:months).fetch(month_index)
      "#{row.fetch(:name)} (#{money(dollars_to_cents(month.fetch(:remaining)))} remaining of #{money(dollars_to_cents(month.fetch(:planned)))} planned)"
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

    def business_income_cents
      household.income_sources.where(active: true, source_type: "business").sum do |income|
        Money.monthly_cents(income.amount_cents, income.cadence)
      end
    end

    def recommended_runway_transfer_cents(surplus_cents)
      return 0 unless surplus_cents.positive?

      [ (surplus_cents * 0.6).round, surplus_cents ].min
    end

    def month_label(plan, month_index)
      "#{plan.fetch(:months).fetch(month_index).fetch(:label)} #{plan.fetch(:year)}"
    end

    def target_month_index_from_message
      _month_name, month_number = MonthTerms.detect(normalized_message)
      return unless month_number

      month_number - 1
    end

    def normalized_message
      @normalized_message ||= message.downcase.gsub(/[^a-z0-9\s$.-]/, " ").squish
    end

    def dollars_to_cents(value)
      (value.to_f * 100).round
    end

    def money(cents)
      ActiveSupport::NumberHelper.number_to_currency(
        Money.dollars(cents),
        precision: cents.to_i % 100 == 0 ? 0 : 2
      )
    end
  end
end
