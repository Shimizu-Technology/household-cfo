module HouseholdFinance
  class DataPresenter
    UNRESOLVED_COHORT = Object.new.freeze

    def initialize(household, user: nil, annual_plan: nil, persona: nil, cohort_membership: UNRESOLVED_COHORT, experience_capabilities: nil, ensure_plan: true)
      @household = household
      @user = user
      @annual_plan = annual_plan
      @annual_budget_manager = AnnualBudgetManager.new(household)
      @snapshot_builder = SnapshotBuilder.new(household, annual_budget_manager: @annual_budget_manager, ensure_plan: ensure_plan)
      @cohort_membership = if cohort_membership.equal?(UNRESOLVED_COHORT)
        ::Mia::EffectiveCohortResolver.new(user: user).call
      else
        cohort_membership
      end
      @persona = persona || ::Mia::PersonaResolver.new(user: user, cohort_membership: @cohort_membership).call
      @experience_capabilities = experience_capabilities || CohortExperience::EffectiveCapabilitiesResolver.new(
        cohort_membership: @cohort_membership
      ).call
    end

    def app_data
      payload = {
        workspace: workspace,
        profile: profile,
        dashboard: dashboard,
        budget: budget,
        wealth: wealth,
        mia: mia
      }
      payload[:optionality] = optionality if module_enabled?("optionality")
      payload[:cfoFilter] = cfo_filter if module_enabled?("cfo_filter")
      payload
    end

    def workspace
      status = setup_status
      {
        mode: "real",
        household_id: household.id,
        setup_complete: status.complete?,
        setup_status: status.as_json,
        setup_values: setup_values,
        income_sources: household_income_sources,
        accounts: account_records,
        asset_portfolio: asset_portfolio.as_json,
        debts: debt_records,
        debt_portfolio: debt_portfolio.as_json,
        cohort: cohort_context,
        capabilities: experience_capabilities
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
          monthly_surplus_rate_percent: monthly_surplus_rate_percent,
          runway_months: readiness_available? ? snapshot.fetch(:runway_months) : nil,
          next_safe_to_spend_amount: readiness_available? ? dollars(snapshot.fetch(:safe_to_spend_cents)) : (setup_status.complete? && snapshot.fetch(:debt_minimums_known) ? nil : 0),
          readiness_available: readiness_available?,
          readiness_tone: readiness_available? ? snapshot.fetch(:readiness_tone) : "red",
          readiness_label: readiness_label_for_dashboard
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
      debt_balance_known = snapshot.fetch(:debt_balance_known)
      total_assets_known = snapshot.fetch(:total_assets_known)
      liquid_assets_known = snapshot.fetch(:liquid_assets_known)
      liquid_net_worth_available = debt_balance_known && liquid_assets_known && debt_portfolio.mode == "individual"
      {
        summary: {
          net_worth: debt_balance_known && total_assets_known ? dollars(snapshot.fetch(:net_worth_cents)) : nil,
          liquid_net_worth: liquid_net_worth_available ? dollars(snapshot.fetch(:liquid_assets_cents) - liquid_liabilities_cents) : nil,
          liquid_net_worth_available: liquid_net_worth_available,
          debt_balance_known: debt_balance_known,
          total_assets_known: total_assets_known,
          liquid_assets_known: liquid_assets_known,
          debt_minimums_known: snapshot.fetch(:debt_minimums_known),
          ten_year_surplus_capacity: snapshot.fetch(:debt_minimums_known) ? dollars(ten_year_surplus_capacity_cents) : nil,
          monthly_surplus_available: snapshot.fetch(:debt_minimums_known) ? dollars(monthly_surplus_available_cents) : nil
        },
        milestones: milestones,
        guidance: "Wealth here is not about looking rich. It is about buying back options, lowering panic, and making the next right move visible."
      }
    end

    def optionality
      runway_target = target_runway_months
      unless snapshot.fetch(:debt_minimums_known) && snapshot.fetch(:liquid_assets_known)
        return {
          available: false,
          unavailable_reason: readiness_unavailable_reason,
          scenario: household.primary_goal.presence || "Household stability",
          question: readiness_blocker_question,
          target_runway_months: runway_target,
          current_runway_months: nil,
          monthly_gap: nil,
          choices: [],
          levers: []
        }
      end
      monthly_need_cents = [ snapshot.fetch(:total_outflow_cents), 0 ].max
      target_cash_cents = (monthly_need_cents * runway_target).round
      runway_gap_cents = [ target_cash_cents - snapshot.fetch(:liquid_assets_cents), 0 ].max
      business_income_cents = monthly_business_income_cents
      retained_income_cents = transition_retained_income_cents
      required_business_cents = [ monthly_need_cents - retained_income_cents, 0 ].max
      transition_mode = business_transition_optionality?
      scenario = if transition_mode
        transition_goal&.label || "Founder transition"
      else
        household.primary_goal.presence || "Household stability"
      end
      levers = if transition_mode
        [
          { label: "Income continuing after transition", amount: dollars(retained_income_cents) },
          { label: "Business needs to pay", amount: dollars(required_business_cents) },
          { label: "Current business income", amount: dollars(business_income_cents) },
          { label: "Runway gap", amount: dollars(runway_gap_cents) }
        ]
      else
        [
          { label: "Monthly surplus", amount: dollars([ snapshot.fetch(:baseline_surplus_cents), 0 ].max) },
          { label: "Target runway reserve", amount: dollars(target_cash_cents) },
          { label: "Runway gap", amount: dollars(runway_gap_cents) }
        ]
      end

      {
        available: true,
        scenario: scenario,
        question: household.primary_goal.presence || "What would it take to safely make the next move?",
        target_runway_months: runway_target,
        current_runway_months: snapshot.fetch(:runway_months),
        monthly_gap: dollars(transition_mode ? [ required_business_cents - business_income_cents, 0 ].max : runway_gap_cents),
        choices: transition_mode ? transition_optionality_choices(runway_gap_cents) : goal_optionality_choices(runway_gap_cents),
        levers: levers
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
        emergency_fund: account_type_known?("emergency_fund") ? dollars(account_by_type("emergency_fund")) : nil,
        other_assets: account_type_known?("other") ? dollars(account_by_type("other")) : nil,
        credit_card_debt: debt_portfolio.balance_known? ? dollars(debt_portfolio.total_balance_cents) : nil,
        debt_payment: debt_portfolio.minimum_payment_known? ? dollars(debt_portfolio.monthly_minimum_cents) : nil,
        target_runway_months: target_runway_months
      }
    end

    def debt_records
      debts.map do |debt|
        {
          id: debt.id,
          label: debt.label,
          debt_type: debt.debt_type,
          balance: debt.balance_known? ? dollars(debt.balance_cents) : nil,
          minimum_payment: debt.minimum_payment_known? ? dollars(debt.minimum_payment_cents) : nil,
          interest_rate_percent: debt.interest_rate_percent&.to_f,
          active: debt.active?,
          archived_at: debt.archived_at&.iso8601,
          source_type: debt.source_type,
          source_metadata: debt.source_metadata
        }
      end
    end

    def account_records
      accounts.map do |account|
        observation = account.plaid_account
        {
          id: account.id,
          label: account.label,
          account_type: account.account_type,
          balance: account.balance_known? ? dollars(account.balance_cents) : nil,
          balance_as_of_on: account.balance_as_of_on&.iso8601,
          active: account.active?,
          archived_at: account.archived_at&.iso8601,
          source_type: account.source_type,
          source_metadata: account.source_metadata,
          plaid_link: observation && {
            plaid_account_id: observation.id,
            institution_name: observation.plaid_item.institution_name,
            name: observation.name,
            mask: observation.mask,
            current_balance: observation.current_balance_cents.nil? ? nil : dollars(observation.current_balance_cents),
            available_balance: observation.available_balance_cents.nil? ? nil : dollars(observation.available_balance_cents),
            observed_at: observation.plaid_item.last_synced_at&.iso8601,
            active: PlaidIntegration::AccountEligibility.new(observation).active_observation?,
            observation_newer_than_saved: observation.plaid_item.last_synced_at.present? &&
              (account.plaid_reconciled_at.nil? || observation.plaid_item.last_synced_at > account.plaid_reconciled_at)
          }
        }
      end
    end

    def cohort_context
      membership = cohort_membership
      return unless membership

      {
        id: membership.cohort.id,
        name: membership.cohort.name,
        role: membership.role,
        status: membership.cohort.status
      }
    end

    private

    attr_reader :experience_capabilities

    def module_enabled?(id)
      experience_capabilities.fetch(:modules).any? { |item| item.fetch(:id) == id && item.fetch(:enabled) }
    end

    def setup_status
      @setup_status ||= SetupStatus.new(household)
    end

    attr_reader :household, :user, :snapshot_builder, :persona, :cohort_membership

    def annual_plan
      @annual_plan ||= annual_budget_manager.plan_data
    end

    def annual_budget_manager
      @annual_budget_manager
    end

    def snapshot
      @snapshot ||= snapshot_builder.call
    end

    def memberships
      @memberships ||= household.household_memberships.includes(:user).to_a
    end

    def income_sources
      @income_sources ||= household.income_sources.includes(:income_schedule_entries).order(:source_type, :label).select { |source| source.effective_on?(Date.current) }
    end

    def household_income_sources
      @household_income_sources ||= IncomeSourcePresenter.collection(household.income_sources)
    end

    def expense_items
      @expense_items ||= household.expense_items.where(active: true).order(:stack_key, :label).to_a
    end

    def accounts
      @accounts ||= household.accounts.includes(plaid_account: :plaid_item).order(:active, :account_type, :label).to_a
    end

    def active_accounts
      accounts.select(&:active?)
    end

    def asset_portfolio
      @asset_portfolio ||= AssetPortfolio.new(household)
    end

    def readiness_available?
      setup_status.complete? && snapshot.fetch(:debt_minimums_known) && snapshot.fetch(:liquid_assets_known)
    end

    def readiness_unavailable_reason
      return "Enter every required monthly debt minimum, or confirm a $0 household summary, before using cash guidance." unless snapshot.fetch(:debt_minimums_known)
      return "Add at least one liquid account and enter every active liquid balance before using runway or safe-to-spend guidance." unless snapshot.fetch(:liquid_assets_known)

      "Finish the starting picture before using cash guidance."
    end

    def readiness_blocker_question
      return "Complete the monthly debt minimums under My Profile first." unless snapshot.fetch(:debt_minimums_known)
      return "Add or update liquid account balances under Accounts & assets first." unless snapshot.fetch(:liquid_assets_known)

      "Finish the starting picture before modeling optionality."
    end

    def debts
      @debts ||= household.debts.order(:debt_type, :label).to_a
    end

    def debt_portfolio
      @debt_portfolio ||= DebtPortfolio.new(household)
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
          summary: "Current recurring monthly income. One-time bonuses stay in the month where they belong in the annual plan.",
          items: income_sources.map { |income| { label: income.label, amount: dollars(current_recurring_income_cents(income)) } }
        },
        {
          label: "Expenses",
          summary: "Bills, choices, and the things life always seems to throw at you.",
          items: expense_items.map { |expense| { label: expense.label, amount: dollars(current_expense_period_cents(expense)) } }
        },
        {
          label: "Savings & Debt",
          summary: "Runway, cash, credit cards, loans, and the next stability target.",
          items: savings_and_debt_items
        }
      ]
    end

    def savings_and_debt_items
      account_items = active_accounts.select(&:balance_known?).map { |account| { label: account.label, amount: dollars(account.balance_cents) } }
      debt_items = if debt_portfolio.mode == "summary"
        debt_portfolio.balance_known? && debt_portfolio.total_balance_cents.positive? ? [ { label: "Household debt summary", amount: -dollars(debt_portfolio.total_balance_cents) } ] : []
      else
        debts.select { |debt| debt.active? && debt.balance_known? }.map { |debt| { label: debt.label, amount: -dollars(debt.balance_cents) } }
      end
      account_items + debt_items
    end

    def monthly_surplus_rate_percent
      income = snapshot.fetch(:monthly_income_cents)
      return 0 if income <= 0

      ([ snapshot.fetch(:baseline_surplus_cents), 0 ].max / income.to_f * 100).round
    end

    def account_rows
      asset_rows = active_accounts.select(&:balance_known?).map do |account|
        { name: account.label, type: account.account_type, balance: dollars(account.balance_cents) }
      end
      debt_rows = if debt_portfolio.mode == "summary"
        debt_portfolio.balance_known? && debt_portfolio.total_balance_cents.positive? ? [ { name: "Household debt summary", type: "debt", balance: -dollars(debt_portfolio.total_balance_cents) } ] : []
      else
        debts.select { |debt| debt.active? && debt.balance_known? }.map do |debt|
          { name: debt.label, type: "debt", balance: -dollars(debt.balance_cents) }
        end
      end
      asset_rows + debt_rows
    end

    def alerts
      unless setup_status.complete?
        return [
          { tone: "yellow", title: "Finish your starting picture", body: setup_guidance }
        ]
      end

      unless snapshot.fetch(:debt_minimums_known)
        return [
          { tone: "yellow", title: "Debt minimums needed", body: "Add every required monthly minimum, or confirm a $0 household summary, before using readiness or cash-flow guidance." },
          { tone: debt_tone, title: "Debt focus", body: debt_body }
        ]
      end

      unless snapshot.fetch(:liquid_assets_known)
        return [
          { tone: "yellow", title: "Liquid balances needed", body: readiness_unavailable_reason },
          { tone: debt_tone, title: "Debt focus", body: debt_body }
        ]
      end

      [
        { tone: snapshot.fetch(:readiness_tone), title: "Readiness", body: snapshot.fetch(:readiness_label) },
        { tone: snapshot.fetch(:baseline_surplus_cents).positive? ? "green" : "red", title: "Baseline", body: baseline_body },
        { tone: debt_tone, title: "Debt focus", body: debt_body }
      ]
    end

    def baseline_body
      return "Monthly debt minimums are not fully entered, so the baseline is not available yet." unless snapshot.fetch(:debt_minimums_known)

      surplus = dollars(snapshot.fetch(:baseline_surplus_cents))
      return "Your baseline has #{ActiveSupport::NumberHelper.number_to_currency(surplus, precision: 0)} left after planned outflow." if surplus.positive?

      "Your planned outflow is above income. Pause extras and rebuild the baseline before adding new commitments."
    end

    def debt_tone
      return "yellow" unless snapshot.fetch(:debt_balance_known)

      snapshot.fetch(:total_debt_cents).positive? ? "yellow" : "green"
    end

    def debt_body
      return "Debt balances are not fully entered yet. Add the missing balances or confirm a $0 household summary before using debt totals." unless snapshot.fetch(:debt_balance_known)

      debt = dollars(snapshot.fetch(:total_debt_cents))
      return "No debt entered yet. Add debts if you want Mia to pressure-test payoff decisions." if debt.zero?

      "You have #{ActiveSupport::NumberHelper.number_to_currency(debt, precision: 0)} in debt entered. Keep minimums protected before funding wants."
    end

    def next_steps
      unless setup_status.complete?
        return [
          setup_guidance,
          "Tell Mia the missing details for review, or enter them in Manual setup. Use 0 when an amount does not apply.",
          "Review and confirm the setup before relying on readiness or safe-to-spend."
        ]
      end

      unless snapshot.fetch(:debt_minimums_known)
        return [
          "Add every required debt minimum, or confirm a $0 household summary.",
          "Review those debt details before relying on readiness or safe-to-spend.",
          "Ask Mia to compare debt options after the monthly baseline is complete."
        ]
      end

      unless snapshot.fetch(:liquid_assets_known)
        return [
          readiness_unavailable_reason,
          "Mark a balance as unknown instead of entering $0 when you do not know it.",
          "Ask Mia to help add or update an account for review."
        ]
      end

      steps = []
      steps << "Add income and Expense Stack numbers." if snapshot.fetch(:monthly_income_cents).zero? || snapshot.fetch(:total_expenses_cents).zero?
      steps << "Protect fixed bills and minimum debt payments first."
      steps << spending_step
      steps << "Ask Mia to pressure-test one decision before money leaves the household."
      steps.first(3)
    end

    def spending_step
      return "Enter every debt minimum before setting a spending cap." unless snapshot.fetch(:debt_minimums_known)

      if snapshot.fetch(:readiness_tone) == "red"
        return "Pause new wants and direct available surplus to essential bills, expected expenses, and runway until the household reaches Yellow."
      end

      safe_to_spend = snapshot.fetch(:safe_to_spend_cents)
      return "Pause new wants until baseline surplus is positive." unless safe_to_spend.positive?

      "Keep wants under #{ActiveSupport::NumberHelper.number_to_currency(dollars(safe_to_spend), precision: 0)} until the next check-in."
    end

    def action_center
      current_year = Date.current.year
      current_year_range = Date.new(current_year, 1, 1)..Date.new(current_year, 12, 31)
      transaction_reviews = household.transaction_drafts.pending.where(occurred_on: current_year_range).count
      action_reviews = household.mia_action_drafts.pending
        .where("draft_type IN (:timeless) OR year = :year", timeless: %w[household_setup debt_plan], year: current_year)
        .count

      {
        transaction_review_count: transaction_reviews,
        mia_action_review_count: action_reviews,
        total_review_count: transaction_reviews + action_reviews,
        current_month_label: Date.current.strftime("%B"),
        current_month_index: Date.current.month - 1,
        current_year: current_year
      }
    end

    def coach_read
      unless setup_status.complete?
        return {
          title: "Finish your starting picture.",
          body: "#{setup_guidance} Mia will calculate readiness and safe-to-spend after you review and confirm those details."
        }
      end

      unless snapshot.fetch(:debt_minimums_known)
        return {
          title: "Finish the debt minimums before making a cash-flow call.",
          body: "At least one monthly debt minimum is unknown. Add it under My Profile, or use a confirmed $0 household summary, before relying on readiness, baseline surplus, or safe-to-spend."
        }
      end

      unless snapshot.fetch(:liquid_assets_known)
        return {
          title: "Finish the liquid account picture before making a cash-flow call.",
          body: readiness_unavailable_reason
        }
      end

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
      unless snapshot.fetch(:debt_minimums_known) && snapshot.fetch(:liquid_assets_known)
        return {
          available: false,
          unavailable_reason: readiness_unavailable_reason,
          current_runway_months: nil,
          target_runway_months: target_months,
          protected_liquid_amount: dollars(snapshot.fetch(:liquid_assets_cents)),
          monthly_surplus: nil,
          yellow: readiness_milestone(tone: "yellow", runway_months: target_months / 2.0, target_cents: 0, liquid_assets_cents: 0, cash_flow_ready: false),
          green: readiness_milestone(tone: "green", runway_months: target_months, target_cents: 0, liquid_assets_cents: 0, cash_flow_ready: false)
        }
      end
      yellow_months = target_months / 2.0
      monthly_outflow_cents = snapshot.fetch(:total_outflow_cents)
      liquid_assets_cents = snapshot.fetch(:liquid_assets_cents)
      monthly_surplus_cents = snapshot.fetch(:baseline_surplus_cents)

      {
        available: true,
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
      unless setup_status.complete?
        return [
          "Help me finish my household setup",
          "What setup details are still missing?",
          "I want to enter my starting household numbers",
          "How do I confirm my starting picture?"
        ]
      end

      unless snapshot.fetch(:debt_minimums_known)
        return [
          "Help me finish my debt minimums",
          "Which debt details are still missing?",
          "How do I confirm that no debt minimum is due?",
          "Show me where to update debt tracking"
        ]
      end

      unless snapshot.fetch(:liquid_assets_known)
        return [
          "Help me add my checking account",
          "Which account balances are still unknown?",
          "Update my emergency fund balance",
          "Why is cash guidance unavailable?"
        ]
      end

      status = snapshot.fetch(:readiness_tone).capitalize

      [
        "Can I buy the purse?",
        "Why is my readiness #{status}?",
        "Emergency fund or debt first?",
        "Can I leave my job?"
      ]
    end

    def ten_year_surplus_capacity_cents
      monthly_surplus_available_cents * 12 * 10
    end

    def monthly_surplus_available_cents
      [ snapshot.fetch(:baseline_surplus_cents), 0 ].max
    end

    def milestones
      unless snapshot.fetch(:debt_balance_known) && snapshot.fetch(:debt_minimums_known) && snapshot.fetch(:liquid_assets_known)
        label, unit = if !snapshot.fetch(:debt_balance_known) || !snapshot.fetch(:debt_minimums_known)
          [ "Debt details needed", "Add debt balances and monthly minimums under My Profile" ]
        else
          [ "Liquid balances needed", "Add checking, savings, or emergency-fund balances under Accounts & assets" ]
        end
        return [
          { kind: "status", label: label, current: 0, target: 0, unit: unit, status: "yellow" }
        ]
      end

      runway_target = target_runway_months
      debt_total = dollars(snapshot.fetch(:total_debt_cents))
      [
        { kind: "progress", label: "Runway target", current: snapshot.fetch(:runway_months), target: runway_target, unit: "months", status: snapshot.fetch(:readiness_tone) },
        debt_milestone(debt_total),
        { kind: "progress", label: "Protected liquid runway", current: dollars(snapshot.fetch(:liquid_assets_cents)), target: dollars(snapshot.fetch(:total_outflow_cents) * runway_target), unit: "dollars", status: full_runway_target_reached? ? "green" : "yellow" }
      ]
    end

    def full_runway_target_reached?
      target_cents = (snapshot.fetch(:total_outflow_cents) * target_runway_months).round
      target_cents.positive? && snapshot.fetch(:liquid_assets_cents) >= target_cents
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
      stored_target = goals.find { |goal| goal.goal_type == "runway" }&.target_months.to_f
      stored_target.positive? ? stored_target : SnapshotBuilder::DEFAULT_RUNWAY_TARGET_MONTHS
    end

    def transition_retained_income_cents
      # Employment is the income being replaced in a founder/career transition.
      # Independently recurring rental/passive sources remain available. A job
      # counts only when an approved, currently effective recurring change
      # proves that its pay was reduced AND the participant explicitly marked
      # that exact schedule entry as continuing after their transition. Never
      # infer retention or departure from free-form goal wording.
      # Bonus and "other" are too ambiguous to assume without an attestation.
      income_sources
        .select { |income| income.source_type.in?(%w[rental passive]) || approved_continuing_salary?(income) }
        .sum { |income| current_recurring_income_cents(income) }
    end

    def approved_continuing_salary?(income)
      return false unless income.source_type == "job"

      changes = income.income_schedule_entries
        .select { |entry| entry.entry_type == "recurring_change" && entry.effective_on <= Date.current.end_of_month }
        .sort_by { |entry| [ entry.effective_on, entry.id ] }
      return false unless changes.last&.retained_after_transition?

      preceding = changes[-2]
      previous_amount_cents = preceding&.amount_cents || income.amount_cents
      previous_cadence = preceding&.cadence || income.cadence

      Money.annualized_cents(changes.last.amount_cents, changes.last.cadence) <
        Money.annualized_cents(previous_amount_cents, previous_cadence)
    end

    def monthly_business_income_cents
      income_sources.select { |income| income.source_type == "business" }.sum { |income| current_recurring_income_cents(income) }
    end

    def business_transition_optionality?
      goal_text = [ transition_goal&.label, household.primary_goal ].compact.join(" ")
      return true if goal_text.match?(/\b(?:business|career|founder|job|leave|quit|replace income|reduce hours|cut back hours|transition|full[- ]time|self[- ]employ)\b/i)
      return false if household.primary_goal.present?

      monthly_business_income_cents.positive?
    end

    def transition_optionality_choices(runway_gap_cents)
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

    def goal_optionality_choices(runway_gap_cents)
      surplus_positive = snapshot.fetch(:baseline_surplus_cents).positive?
      readiness_tone = snapshot.fetch(:readiness_tone)
      goal_fit_label = if !surplus_positive
        "Stabilize first"
      elsif readiness_tone == "green"
        "Ready to fund"
      elsif readiness_tone == "yellow"
        "Start steadily"
      else
        "Protect the baseline first"
      end

      [
        {
          label: "Protect the baseline",
          fit_label: surplus_positive ? "Best fit now" : "Stabilize first",
          fit_tone: surplus_positive ? "green" : "red",
          upside: "Keeps essential bills and expected expenses protected while the plan settles.",
          tradeoff: "The primary goal may move more slowly at first."
        },
        {
          label: "Build the goal fund",
          fit_label: goal_fit_label,
          fit_tone: surplus_positive ? readiness_tone : "red",
          upside: "Directs a repeatable part of monthly surplus toward the household's stated goal.",
          tradeoff: "Requires a consistent limit on flexible spending."
        },
        {
          label: "Accelerate the goal",
          fit_label: runway_gap_cents.zero? && surplus_positive ? "Possible with safeguards" : "Not ready yet",
          fit_tone: runway_gap_cents.zero? && surplus_positive ? "yellow" : "red",
          upside: "Moves more available cash toward the goal once the household baseline is protected.",
          tradeoff: runway_gap_cents.zero? ? "Keep a written buffer for irregular expenses." : "Close the runway gap before increasing the pace."
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
      unless setup_status.complete?
        return [ "Non-essential purchase", "Extra debt payment", "Runway transfer" ].map do |item|
          {
            item: item,
            amount: 0,
            recommendation: "Wait",
            reason: "Finish and confirm the household starting picture before Mia recommends a money decision."
          }
        end
      end

      unless snapshot.fetch(:debt_minimums_known)
        return [ "Non-essential purchase", "Extra debt payment", "Runway transfer" ].map do |item|
          {
            item: item,
            amount: 0,
            recommendation: "Wait",
            reason: "Enter every required monthly debt minimum, or confirm a $0 household summary, before Mia calculates available cash."
          }
        end
      end

      unless snapshot.fetch(:liquid_assets_known)
        return [ "Non-essential purchase", "Extra debt payment", "Runway transfer" ].map do |item|
          { item: item, amount: 0, recommendation: "Wait", reason: readiness_unavailable_reason }
        end
      end

      safe = [ dollars(snapshot.fetch(:safe_to_spend_cents)), 0 ].max
      debt_balance_known = snapshot.fetch(:debt_balance_known)
      debt_entered = debt_balance_known && snapshot.fetch(:total_debt_cents).positive?
      baseline_positive = snapshot.fetch(:baseline_surplus_cents).positive?
      runway_met = snapshot.fetch(:runway_months) >= target_runway_months
      extra_debt_ready = debt_entered && baseline_positive && safe.positive? && snapshot.fetch(:readiness_tone) != "red"
      [
        {
          item: "Non-essential purchase",
          amount: safe,
          recommendation: safe.positive? ? "Pause" : "Wait",
          reason: safe.positive? ? "Only approve wants that fit inside true surplus after bills, sinking funds, and debt minimums." : "Baseline is not ready for wants yet. Protect essentials first."
        },
        {
          item: "Extra debt payment",
          amount: extra_debt_ready ? safe : 0,
          recommendation: extra_debt_ready ? "Approve" : "Wait",
          reason: if !debt_balance_known
            "Enter every debt balance before Mia prioritizes an extra payment. Partial totals are not used for payoff decisions."
                  elsif debt_entered
            "Debt payoff helps breathing room, but only after fixed bills and runway are protected."
                  else
            "No debt entered yet. Add debts before Mia can prioritize payoff."
                  end
        },
        {
          item: "Runway transfer",
          amount: [ dollars(snapshot.fetch(:baseline_surplus_cents)), 0 ].max,
          recommendation: runway_met ? "Optional" : (baseline_positive ? "Approve" : "Wait"),
          reason: runway_transfer_reason(runway_met, baseline_positive)
        }
      ]
    end

    def setup_guidance
      missing = setup_status.as_json.fetch(:missing_fields).pluck(:label).to_sentence
      "Complete these setup details first: #{missing}."
    end

    def readiness_label_for_dashboard
      return "Setup incomplete — finish your starting picture" unless setup_status.complete?
      return "Debt minimums needed — add them or confirm none are due" unless snapshot.fetch(:debt_minimums_known)
      return "Liquid balances needed — add them before using cash guidance" unless snapshot.fetch(:liquid_assets_known)

      snapshot.fetch(:readiness_label)
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
      unless snapshot.fetch(:debt_balance_known) && snapshot.fetch(:debt_minimums_known)
        return [
          { label: "Debt details needed", current: 0, target: 0 }
        ]
      end

      [
        { label: "Emergency fund", current: dollars(account_by_type("emergency_fund")), target: dollars(snapshot.fetch(:total_outflow_cents) * target_runway_months) },
        { label: "Debt payoff", current: dollars(snapshot.fetch(:total_debt_cents)), target: 0 },
        { label: "Monthly business revenue", current: dollars(monthly_business_income_cents), target: dollars([ snapshot.fetch(:total_outflow_cents) - transition_retained_income_cents, 0 ].max) }
      ]
    end

    def chat_message_page(before_id:, limit:)
      return { messages: [], oldest_message_id: nil, older_message_count: 0 } unless user
      return { messages: [], oldest_message_id: nil, older_message_count: 0 } unless chat_session

      page_limit = (limit.presence || 60).to_i.clamp(1, 100)
      relation = chat_session.chat_messages.includes(
        coach_content_citations: [
          :coach_content_pack_version,
          { coach_content_item_version: :coach_content_item }
        ]
      )
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
      income_sources.select { |income| income.source_type == source_type }.sum { |income| current_recurring_income_cents(income) }
    end

    def current_recurring_income_cents(income)
      IncomeTimeline.recurring_monthly_cents(income, on: Date.current)
    end

    def expenses_by_stack(stack_key)
      expense_items.select { |expense| expense.stack_key == stack_key }.sum { |expense| current_expense_period_cents(expense) }
    end

    def current_expense_period_cents(expense)
      Money.period_cents(expense.amount_cents, expense.cadence, month: Date.current.month)
    end

    def account_by_type(account_type)
      active_accounts.select { |account| account.account_type == account_type && account.balance_known? }.sum(&:balance_cents)
    end

    def account_type_known?(account_type)
      matches = active_accounts.select { |account| account.account_type == account_type }
      matches.any? && matches.all?(&:balance_known?)
    end

    def debt_by_type(debt_type)
      debts.select { |debt| debt.active? && debt.balance_known? && debt.debt_type == debt_type }.sum(&:balance_cents)
    end

    def liquid_liabilities_cents
      debt_by_type("credit_card")
    end

    def debt_payments_by_type(debt_type)
      debts.select { |debt| debt.active? && debt.minimum_payment_known? && debt.debt_type == debt_type }.sum(&:minimum_payment_cents)
    end

    def dollars(cents)
      Money.dollars(cents)
    end
  end
end
