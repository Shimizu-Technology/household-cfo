module HouseholdFinance
  class DataPresenter
    def initialize(household, user: nil, annual_plan: nil)
      @household = household
      @user = user
      @annual_plan = annual_plan
      @snapshot_builder = SnapshotBuilder.new(household)
      @persona = ::Mia::Persona.default
    end

    def app_data
      {
        workspace: workspace,
        profile: profile,
        dashboard: dashboard,
        budget: budget,
        wealth: wealth,
        optionality: optionality,
        cfoFilter: cfo_filter,
        mia: mia
      }
    end

    def workspace
      {
        mode: "real",
        household_id: household.id,
        setup_complete: snapshot.fetch(:profile_completeness) >= 70,
        setup_values: setup_values
      }
    end

    def profile
      {
        household: {
          name: household.name,
          stage: household.stage.presence || "First cohort",
          location: household.location.presence || "Guam",
          primary_goal: household.primary_goal.presence || "Build a clear monthly money rhythm."
        },
        coach: {
          name: persona.name,
          role: persona.role,
          voice: persona.voice_summary
        },
        members: members,
        priorities: priorities,
        completeness: snapshot.fetch(:profile_completeness),
        uploads: uploads,
        sections: profile_sections
      }
    end

    def dashboard
      {
        summary: {
          monthly_income: dollars(snapshot.fetch(:monthly_income_cents)),
          fixed_expenses: dollars(snapshot.fetch(:stack_totals_cents).fetch("non_discretionary")),
          flexible_spend: dollars(snapshot.fetch(:stack_totals_cents).fetch("discretionary")),
          debt_payments: dollars(snapshot.fetch(:debt_payments_cents)),
          savings_rate_percent: savings_rate_percent,
          runway_months: snapshot.fetch(:runway_months),
          next_safe_to_spend_amount: dollars(snapshot.fetch(:safe_to_spend_cents)),
          readiness_tone: snapshot.fetch(:readiness_tone),
          readiness_label: snapshot.fetch(:readiness_label)
        },
        action_center: action_center,
        coach_read: coach_read,
        readiness_path: readiness_path,
        accounts: account_rows,
        alerts: alerts,
        next_steps: next_steps
      }
    end

    def budget
      {
        framework: "Expense Stack",
        intro: "Most budgets collapse life into bills versus fun. Household CFO separates the expenses that surprise you before they turn into emergencies.",
        monthly_income: dollars(snapshot.fetch(:monthly_income_cents)),
        total_monthly_outflow: dollars(snapshot.fetch(:total_outflow_cents)),
        baseline_surplus: dollars(snapshot.fetch(:baseline_surplus_cents)),
        stacks: snapshot_builder.budget_stacks,
        custom_categories_note: "Rename these into the language of your household. The stack matters more than perfect accounting labels.",
        annual_plan: annual_plan
      }
    end

    def wealth
      {
        summary: {
          net_worth: dollars(snapshot.fetch(:net_worth_cents)),
          liquid_net_worth: dollars(snapshot.fetch(:liquid_assets_cents) - liquid_liabilities_cents),
          retirement_projection: dollars(retirement_projection_cents),
          monthly_wealth_building: dollars(monthly_wealth_building_cents)
        },
        milestones: milestones,
        guidance: "Wealth here is not about looking rich. It is about buying back options, lowering panic, and making the next right move visible."
      }
    end

    def optionality
      runway_target = target_runway_months
      monthly_need_cents = [ snapshot.fetch(:total_outflow_cents), 0 ].max
      target_cash_cents = (monthly_need_cents * runway_target).round
      runway_gap_cents = [ target_cash_cents - snapshot.fetch(:liquid_assets_cents), 0 ].max
      business_income_cents = monthly_business_income_cents
      required_business_cents = [ monthly_need_cents - stable_income_cents, 0 ].max

      {
        scenario: transition_goal&.label || "Founder transition",
        question: household.primary_goal.presence || "What would it take to safely make the next move?",
        target_runway_months: runway_target,
        current_runway_months: snapshot.fetch(:runway_months),
        monthly_gap: dollars([ required_business_cents - business_income_cents, 0 ].max),
        choices: optionality_choices(runway_gap_cents),
        levers: [
          { label: "Business needs to pay", amount: dollars(required_business_cents) },
          { label: "Current business income", amount: dollars(business_income_cents) },
          { label: "Runway gap", amount: dollars(runway_gap_cents) }
        ]
      }
    end

    def cfo_filter
      {
        framework: "CFO Filter",
        prompt: "Before money leaves the household, ask whether this spend protects stability, creates optionality, or moves the dream forward.",
        decisions: decisions,
        targets: targets,
        priority_stack: [ "Protect the roof", "Protect food/gas", "Protect runway", "Attack high-interest debt", "Fund the dream with evidence" ]
      }
    end

    def mia(before_id: nil, limit: 60)
      page = chat_message_page(before_id: before_id, limit: limit)
      {
        messages: page.fetch(:messages),
        oldest_message_id: page[:oldest_message_id],
        older_message_count: page.fetch(:older_message_count),
        has_older_messages: page.fetch(:older_message_count).positive?,
        quick_prompts: quick_prompts,
        disclaimer: persona.disclaimer
      }
    end

    def setup_values
      {
        household_name: household.name,
        primary_goal: household.primary_goal.to_s,
        primary_income: dollars(income_by_type("job")),
        business_income: dollars(income_by_type("business")),
        fixed_expenses: dollars(expenses_by_stack("non_discretionary")),
        flexible_spend: dollars(expenses_by_stack("discretionary")),
        expected_sinking_fund: dollars(expenses_by_stack("sinking_expected")),
        unexpected_sinking_fund: dollars(expenses_by_stack("sinking_unexpected")),
        emergency_fund: dollars(account_by_type("emergency_fund")),
        other_assets: dollars(account_by_type("other")),
        credit_card_debt: dollars(debt_by_type("credit_card")),
        debt_payment: dollars(debt_payments_by_type("credit_card")),
        target_runway_months: target_runway_months
      }
    end

    private

    attr_reader :household, :user, :snapshot_builder, :persona

    def annual_plan
      @annual_plan ||= annual_budget_manager.plan_data
    end

    def annual_budget_manager
      @annual_budget_manager ||= AnnualBudgetManager.new(household)
    end

    def snapshot
      @snapshot ||= snapshot_builder.call
    end

    def memberships
      @memberships ||= household.household_memberships.includes(:user).to_a
    end

    def income_sources
      @income_sources ||= household.income_sources.where(active: true).order(:source_type, :label).to_a
    end

    def expense_items
      @expense_items ||= household.expense_items.where(active: true).order(:stack_key, :label).to_a
    end

    def accounts
      @accounts ||= household.accounts.order(:account_type, :label).to_a
    end

    def debts
      @debts ||= household.debts.order(:debt_type, :label).to_a
    end

    def goals
      @goals ||= household.goals.order(:priority).to_a
    end

    def chat_session
      return nil unless user

      @chat_session ||= household.chat_sessions.find_by(user: user)
    end

    def members
      memberships.map do |membership|
        {
          name: membership.user.full_name,
          role: membership.role.titleize,
          age_range: ""
        }
      end.presence || [ { name: user&.full_name || "You", role: "Primary household CFO", age_range: "" } ]
    end

    def priorities
      [
        "Know what is safe to spend",
        "Protect the emergency fund",
        "Plan the next big move",
        "Reduce debt without losing momentum"
      ]
    end

    def uploads
      [
        { label: "Upload spreadsheet", kind: "spreadsheet", status: "Private extraction with review before apply", accepts: ".xlsx, .xls, .csv" },
        { label: "Upload statement", kind: "statement", status: "Transactions draft into the correct months for review", accepts: ".pdf, .csv, .png, .jpg" },
        { label: "Upload pay stub", kind: "paystub", status: "Income facts stay pending until you approve them", accepts: ".pdf, .png, .jpg" }
      ]
    end

    def profile_sections
      [
        {
          label: "Income",
          summary: "Base pay, business income, rental income, bonuses, and other monthly money coming in.",
          items: income_sources.map { |income| { label: income.label, amount: dollars(Money.monthly_cents(income.amount_cents, income.cadence)) } }
        },
        {
          label: "Expenses",
          summary: "Bills, choices, and the things life always seems to throw at you.",
          items: expense_items.map { |expense| { label: expense.label, amount: dollars(Money.monthly_cents(expense.amount_cents, expense.cadence)) } }
        },
        {
          label: "Savings & Debt",
          summary: "Runway, cash, credit cards, loans, and the next stability target.",
          items: savings_and_debt_items
        }
      ]
    end

    def savings_and_debt_items
      account_items = accounts.map { |account| { label: account.label, amount: dollars(account.balance_cents) } }
      debt_items = debts.map { |debt| { label: debt.label, amount: -dollars(debt.balance_cents) } }
      account_items + debt_items
    end

    def savings_rate_percent
      income = snapshot.fetch(:monthly_income_cents)
      return 0 if income <= 0

      ([ snapshot.fetch(:baseline_surplus_cents), 0 ].max / income.to_f * 100).round
    end

    def account_rows
      accounts.map do |account|
        { name: account.label, type: account.account_type, balance: dollars(account.balance_cents) }
      end + debts.map do |debt|
        { name: debt.label, type: "debt", balance: -dollars(debt.balance_cents) }
      end
    end

    def alerts
      if snapshot.fetch(:monthly_income_cents).zero? && snapshot.fetch(:total_outflow_cents).zero?
        return [
          { tone: "yellow", title: "Start with the basics", body: "Add monthly income, fixed bills, emergency fund, and debt so Mia can read your real household picture." }
        ]
      end

      [
        { tone: snapshot.fetch(:readiness_tone), title: "Readiness", body: snapshot.fetch(:readiness_label) },
        { tone: snapshot.fetch(:baseline_surplus_cents).positive? ? "green" : "red", title: "Baseline", body: baseline_body },
        { tone: debt_tone, title: "Debt focus", body: debt_body }
      ]
    end

    def baseline_body
      surplus = dollars(snapshot.fetch(:baseline_surplus_cents))
      return "Your baseline has #{ActiveSupport::NumberHelper.number_to_currency(surplus, precision: 0)} left after planned outflow." if surplus.positive?

      "Your planned outflow is above income. Pause extras and rebuild the baseline before adding new commitments."
    end

    def debt_tone
      snapshot.fetch(:total_debt_cents).positive? ? "yellow" : "green"
    end

    def debt_body
      debt = dollars(snapshot.fetch(:total_debt_cents))
      return "No debt entered yet. Add debts if you want Mia to pressure-test payoff decisions." if debt.zero?

      "You have #{ActiveSupport::NumberHelper.number_to_currency(debt, precision: 0)} in debt entered. Keep minimums protected before funding wants."
    end

    def next_steps
      steps = []
      steps << "Add income and Expense Stack numbers." if snapshot.fetch(:monthly_income_cents).zero? || snapshot.fetch(:total_expenses_cents).zero?
      steps << "Protect fixed bills and minimum debt payments first."
      steps << spending_step
      steps << "Ask Mia to pressure-test one decision before money leaves the household."
      steps.first(3)
    end

    def spending_step
      if snapshot.fetch(:readiness_tone) == "red"
        return "Pause new wants and direct available surplus to essential bills, expected expenses, and runway until the household reaches Yellow."
      end

      safe_to_spend = snapshot.fetch(:safe_to_spend_cents)
      return "Pause new wants until baseline surplus is positive." unless safe_to_spend.positive?

      "Keep wants under #{ActiveSupport::NumberHelper.number_to_currency(dollars(safe_to_spend), precision: 0)} until the next check-in."
    end

    def action_center
      transaction_reviews = household.transaction_drafts.pending.count
      action_reviews = household.mia_action_drafts.pending.count

      {
        transaction_review_count: transaction_reviews,
        mia_action_review_count: action_reviews,
        total_review_count: transaction_reviews + action_reviews,
        current_month_label: Date.current.strftime("%B"),
        current_month_index: Date.current.month - 1,
        current_year: Date.current.year
      }
    end

    def coach_read
      case snapshot.fetch(:readiness_tone)
      when "green"
        {
          title: "Keep the household plan steady.",
          body: "Your target runway and positive monthly cash flow are both in place. Protect expected expenses, review actuals, and avoid turning a Green month into permission for a permanent spending increase."
        }
      when "yellow"
        {
          title: "Close the remaining runway gap.",
          body: "Your monthly cash flow is holding, but the household still needs more protected runway. Keep expected expenses funded and direct planned surplus toward the runway target before expanding wants."
        }
      else
        {
          title: "Protect the baseline and build runway.",
          body: "The household is Red because essential stability or runway is not protected yet. Pause new wants, review pending activity, cover expected expenses, and direct available surplus toward the Yellow runway threshold."
        }
      end
    end

    def readiness_path
      target_months = snapshot.fetch(:target_runway_months).to_f
      yellow_months = target_months / 2.0
      monthly_outflow_cents = snapshot.fetch(:total_outflow_cents)
      liquid_assets_cents = snapshot.fetch(:liquid_assets_cents)
      monthly_surplus_cents = snapshot.fetch(:baseline_surplus_cents)

      {
        current_runway_months: snapshot.fetch(:runway_months),
        target_runway_months: target_months,
        protected_liquid_amount: dollars(liquid_assets_cents),
        monthly_surplus: dollars(monthly_surplus_cents),
        yellow: readiness_milestone(
          tone: "yellow",
          runway_months: yellow_months,
          target_cents: monthly_outflow_cents * yellow_months,
          liquid_assets_cents: liquid_assets_cents,
          cash_flow_ready: monthly_surplus_cents >= 0
        ),
        green: readiness_milestone(
          tone: "green",
          runway_months: target_months,
          target_cents: monthly_outflow_cents * target_months,
          liquid_assets_cents: liquid_assets_cents,
          cash_flow_ready: monthly_surplus_cents.positive?
        )
      }
    end

    def readiness_milestone(tone:, runway_months:, target_cents:, liquid_assets_cents:, cash_flow_ready:)
      rounded_target_cents = target_cents.round
      {
        tone: tone,
        runway_months: runway_months.round(1),
        protected_liquid_target: dollars(rounded_target_cents),
        protected_liquid_gap: dollars([ rounded_target_cents - liquid_assets_cents, 0 ].max),
        cash_flow_requirement: tone == "green" ? "Positive monthly cash flow" : "Nonnegative monthly cash flow",
        reached: cash_flow_ready && rounded_target_cents.positive? && liquid_assets_cents >= rounded_target_cents
      }
    end

    def quick_prompts
      status = snapshot.fetch(:readiness_tone).capitalize

      [
        "Can I buy the purse?",
        "Why is my readiness #{status}?",
        "Emergency fund or debt first?",
        "Can I leave my job?"
      ]
    end

    def retirement_projection_cents
      retirement_accounts = accounts.select { |account| account.account_type == "retirement" }.sum(&:balance_cents)
      retirement_accounts + (monthly_wealth_building_cents * 12 * 10)
    end

    def monthly_wealth_building_cents
      [ snapshot.fetch(:baseline_surplus_cents), 0 ].max
    end

    def milestones
      runway_target = target_runway_months
      debt_total = dollars(snapshot.fetch(:total_debt_cents))
      [
        { kind: "progress", label: "Runway target", current: snapshot.fetch(:runway_months), target: runway_target, unit: "months", status: snapshot.fetch(:readiness_tone) },
        debt_milestone(debt_total),
        { kind: "progress", label: "Emergency fund", current: dollars(account_by_type("emergency_fund")), target: dollars(snapshot.fetch(:total_outflow_cents) * runway_target), unit: "dollars", status: snapshot.fetch(:runway_months) >= runway_target ? "green" : "yellow" }
      ]
    end

    def debt_milestone(debt_total)
      return { kind: "debt_remaining", label: "Debt payoff", current: debt_total, target: 0, unit: "dollars", status: "yellow" } if debt_total.positive?
      return { kind: "status", label: "Debt payoff", current: 0, target: 0, unit: "Debt free", status: "green" } if financial_inputs_present?

      { kind: "status", label: "Debt payoff", current: 0, target: 0, unit: "Add debt balances to track payoff", status: "yellow" }
    end

    def transition_goal
      goals.find { |stored_goal| stored_goal.goal_type == "transition" }
    end

    def target_runway_months
      snapshot.fetch(:target_runway_months)
    end

    def stable_income_cents
      income_sources.reject { |income| income.source_type == "business" }.sum { |income| Money.monthly_cents(income.amount_cents, income.cadence) }
    end

    def monthly_business_income_cents
      income_by_type("business")
    end

    def optionality_choices(runway_gap_cents)
      surplus_positive = snapshot.fetch(:baseline_surplus_cents).positive?
      readiness_tone = snapshot.fetch(:readiness_tone)
      [
        {
          label: "Stay the course",
          fit_label: surplus_positive ? "Best fit now" : "Stabilize first",
          fit_tone: surplus_positive ? "green" : "red",
          upside: "Lowest stress and keeps the household baseline protected.",
          tradeoff: "Slower path to the dream move."
        },
        {
          label: "Hybrid transition",
          fit_label: hybrid_fit_label(readiness_tone, surplus_positive: surplus_positive),
          fit_tone: surplus_positive ? readiness_tone : "red",
          upside: "Creates room for the dream while keeping stable income in the picture.",
          tradeoff: "Requires cleaner limits on discretionary spending."
        },
        {
          label: "Leap now",
          fit_label: runway_gap_cents.zero? && surplus_positive ? "Possible with safeguards" : "Not ready yet",
          fit_tone: runway_gap_cents.zero? && surplus_positive ? "yellow" : "red",
          upside: "Maximum focus immediately.",
          tradeoff: runway_gap_cents.zero? ? "Still needs a written runway plan." : "Runway gap should close before cutting stable income."
        }
      ]
    end

    def hybrid_fit_label(readiness_tone, surplus_positive:)
      return "Stabilize first" unless surplus_positive

      case readiness_tone
      when "green" then "Ready to plan"
      when "yellow" then "Plan carefully"
      else "Build runway first"
      end
    end

    def decisions
      safe = [ dollars(snapshot.fetch(:safe_to_spend_cents)), 0 ].max
      debt_entered = snapshot.fetch(:total_debt_cents).positive?
      baseline_positive = snapshot.fetch(:baseline_surplus_cents).positive?
      runway_met = snapshot.fetch(:runway_months) >= target_runway_months
      extra_debt_ready = debt_entered && baseline_positive && snapshot.fetch(:readiness_tone) != "red"
      [
        {
          item: "Non-essential purchase",
          amount: safe,
          recommendation: safe.positive? ? "Pause" : "Wait",
          reason: safe.positive? ? "Only approve wants that fit inside true surplus after bills, sinking funds, and debt minimums." : "Baseline is not ready for wants yet. Protect essentials first."
        },
        {
          item: "Extra debt payment",
          amount: extra_debt_ready ? [ safe, 250 ].max : 0,
          recommendation: extra_debt_ready ? "Approve" : "Wait",
          reason: debt_entered ? "Debt payoff helps breathing room, but only after fixed bills and runway are protected." : "No debt entered yet. Add debts before Mia can prioritize payoff."
        },
        {
          item: "Runway transfer",
          amount: [ dollars(snapshot.fetch(:baseline_surplus_cents)), 0 ].max,
          recommendation: runway_met ? "Optional" : (baseline_positive ? "Approve" : "Wait"),
          reason: runway_transfer_reason(runway_met, baseline_positive)
        }
      ]
    end

    def financial_inputs_present?
      snapshot.fetch(:monthly_income_cents).positive? ||
        snapshot.fetch(:total_outflow_cents).positive? ||
        snapshot.fetch(:total_assets_cents).positive? ||
        snapshot.fetch(:total_debt_cents).positive?
    end

    def runway_transfer_reason(runway_met, baseline_positive)
      return "Runway target is already protected; additional transfers are optional after essentials stay covered." if runway_met
      return "Runway buys options and lowers panic." if baseline_positive

      "No surplus entered yet. Add income and expenses before moving money into runway."
    end

    def targets
      [
        { label: "Emergency fund", current: dollars(account_by_type("emergency_fund")), target: dollars(snapshot.fetch(:total_outflow_cents) * target_runway_months) },
        { label: "Debt payoff", current: dollars(snapshot.fetch(:total_debt_cents)), target: 0 },
        { label: "Monthly business revenue", current: dollars(monthly_business_income_cents), target: dollars([ snapshot.fetch(:total_outflow_cents) - stable_income_cents, 0 ].max) }
      ]
    end

    def chat_message_page(before_id:, limit:)
      return { messages: [], oldest_message_id: nil, older_message_count: 0 } unless user
      return { messages: [], oldest_message_id: nil, older_message_count: 0 } unless chat_session

      page_limit = (limit.presence || 60).to_i.clamp(1, 100)
      relation = chat_session.chat_messages
      relation = relation.where("id < ?", before_id.to_i) if before_id.to_i.positive?
      messages = relation.order(id: :desc).limit(page_limit).to_a.reverse
      imports_by_id = attachment_imports_by_id(messages)
      oldest_message_id = messages.first&.id
      older_message_count = oldest_message_id ? chat_session.chat_messages.where("id < ?", oldest_message_id).count : 0
      {
        messages: messages.map { |message| serialize_chat_message(message, imports_by_id: imports_by_id) },
        oldest_message_id: oldest_message_id,
        older_message_count: older_message_count
      }
    end

    def attachment_imports_by_id(messages)
      ids = messages.flat_map do |message|
        Array(message.attachments).filter_map { |attachment| attachment["document_import_id"] || attachment[:document_import_id] }
      end.map(&:to_i).select(&:positive?).uniq
      return {} if ids.empty?

      household.financial_document_imports.where(id: ids).index_by(&:id)
    end

    def serialize_chat_message(message, imports_by_id:)
      payload = message.as_api_json
      payload[:attachments] = Array(payload[:attachments]).map { |attachment| serialize_chat_attachment(attachment, imports_by_id: imports_by_id) }
      payload
    end

    def serialize_chat_attachment(attachment, imports_by_id:)
      payload = attachment.respond_to?(:deep_symbolize_keys) ? attachment.deep_symbolize_keys : {}
      document_import = imports_by_id[payload[:document_import_id].to_i]
      return payload unless document_import

      payload.merge(
        filename: document_import.filename,
        content_type: document_import.content_type,
        document_kind: document_import.document_kind,
        status: document_import.status,
        source_available: document_import.source_available?,
        preview_url: chat_attachment_preview_url(document_import)
      ).compact
    end

    def chat_attachment_preview_url(document_import)
      return unless S3Service.configured?
      return unless document_import.source_available?
      return unless document_import.content_type.in?(%w[image/jpeg image/png image/webp])

      S3Service.presigned_url(document_import.s3_key, expires_in: 300, filename: document_import.filename, disposition: :inline)
    rescue S3Service::MissingConfigurationError
      nil
    end

    def income_by_type(source_type)
      income_sources.select { |income| income.source_type == source_type }.sum { |income| Money.monthly_cents(income.amount_cents, income.cadence) }
    end

    def expenses_by_stack(stack_key)
      expense_items.select { |expense| expense.stack_key == stack_key }.sum { |expense| Money.monthly_cents(expense.amount_cents, expense.cadence) }
    end

    def account_by_type(account_type)
      accounts.select { |account| account.account_type == account_type }.sum(&:balance_cents)
    end

    def debt_by_type(debt_type)
      debts.select { |debt| debt.debt_type == debt_type }.sum(&:balance_cents)
    end

    def liquid_liabilities_cents
      debt_by_type("credit_card")
    end

    def debt_payments_by_type(debt_type)
      debts.select { |debt| debt.debt_type == debt_type }.sum(&:minimum_payment_cents)
    end

    def dollars(cents)
      Money.dollars(cents)
    end
  end
end
