# frozen_string_literal: true

module HouseholdFinance
  class MiaHypotheticalScenarioAnswerer
    Result = Struct.new(:title, :body, :scenario_value, keyword_init: true)

    TITLES = {
      "purchase" => "Purchase scenario",
      "one_time_income" => "One-time money scenario",
      "essential_expense" => "Essential bill scenario",
      "extra_debt_payment" => "Extra debt payment scenario"
    }.freeze

    def initialize(household, scenario_type:, amount:, label:, effective_on: nil, timing_unavailable: false, annual_budget_manager:, reference_month:)
      @household = household
      @scenario_type = scenario_type.to_s
      @amount_cents = Money.cents!(amount, message: "Scenario amount must be a number")
      @label = label.to_s.squish.presence || TITLES.fetch(@scenario_type)
      @effective_on = effective_on.present? ? Date.iso8601(effective_on.to_s) : nil
      @timing_unavailable = ActiveModel::Type::Boolean.new.cast(timing_unavailable)
      @annual_budget_manager = annual_budget_manager
      @reference_month = reference_month.to_i.clamp(1, 12)
    end

    def call
      raise ArgumentError, "Unsupported scenario type" unless TITLES.key?(scenario_type)
      raise ArgumentError, "Scenario amount must be positive" unless amount_cents.positive?

      body = if timing_unavailable
        "Scenario only — I could not ground the requested timing to a specific month, so I did not apply the selected budget month or model a dated impact. #{money(amount_cents)} remains unapproved and was not saved. Restate the month or date to compare it safely."
      elsif setup_status.complete?
        if liquid_balance_required? && !AssetPortfolio.new(household).liquid_balance_known?
          "Scenario only#{timing_phrase} — #{money(amount_cents)} is not saved or approved. I cannot model safe-to-spend or runway because the liquid account picture is incomplete. Add at least one checking, savings, or emergency-fund account and enter every active liquid balance, then ask again."
        else
          send("#{scenario_type}_answer")
        end
      else
        missing = setup_status.as_json.fetch(:missing_fields).pluck(:label).to_sentence
        "Scenario only#{timing_phrase} — #{money(amount_cents)} is not saved or approved. I cannot model it against readiness until the starting picture is confirmed. Complete these setup details first: #{missing}."
      end

      Result.new(
        title: TITLES.fetch(scenario_type),
        body: body,
        scenario_value: { label: label, display_value: money(amount_cents) }
      )
    end

    private

    attr_reader :household, :scenario_type, :amount_cents, :label, :effective_on, :timing_unavailable, :annual_budget_manager, :reference_month

    def purchase_answer
      safe = snapshot.fetch(:safe_to_spend_cents)
      gap = [ amount_cents - safe, 0 ].max
      "Scenario only#{timing_phrase} — #{label} at #{money(amount_cents)} is not saved, approved, or recorded as spending. The approved safe-to-spend guardrail is #{money(safe)}, so this scenario is #{money(gap)} above that guardrail. This does not prove an account can fund it; name the funding account and budget category before making the CFO call."
    end

    def one_time_income_answer
      "Scenario only#{timing_phrase} — #{label} at #{money(amount_cents)} is not saved or approved income. It would be one-time money, so recurring monthly income remains #{money(snapshot.fetch(:monthly_income_cents))} and readiness does not automatically change. Protect due essentials and expected bills first, then compare the remainder with the gap to the Yellow runway threshold of #{money(yellow_runway_gap_cents)} before considering extra debt or wants."
    end

    def essential_expense_answer
      surplus = snapshot.fetch(:baseline_surplus_cents)
      comparison = if surplus.positive?
        amount_cents > surplus ? "#{money(amount_cents - surplus)} above" : "#{money(surplus - amount_cents)} within"
      else
        "on top of a #{money(surplus.abs)} monthly shortfall in"
      end
      "Scenario only#{timing_phrase} — #{label} at #{money(amount_cents)} is not a saved bill, approved purchase, or transaction. As an essential medical or household bill, it would rank ahead of wants and sits #{comparison} the approved monthly baseline. I cannot calculate an exact runway or account impact until you name the funding account, due date, and any payment plan."
    end

    def extra_debt_payment_answer
      surplus = [ snapshot.fetch(:baseline_surplus_cents), 0 ].max
      remaining = surplus - amount_cents
      comparison = remaining.negative? ? "exceed the approved baseline surplus by #{money(remaining.abs)}" : "leave #{money(remaining)} of approved baseline surplus"
      "Scenario only#{timing_phrase} — the #{money(amount_cents)} extra debt payment is not scheduled, paid, or deducted from the saved debt balance. After protected minimums, it would #{comparison}. Keep expected bills and runway protected before approving extra principal."
    end

    def snapshot
      @snapshot ||= SnapshotBuilder.new(
        household,
        annual_budget_manager: annual_budget_manager,
        reference_date: effective_on || Date.new(annual_budget_manager.year, reference_month, 1),
        ensure_plan: false
      ).call
    end

    def yellow_runway_gap_cents
      target = (snapshot.fetch(:total_outflow_cents) * snapshot.fetch(:target_runway_months).to_f / 2.0).round
      [ target - snapshot.fetch(:liquid_assets_cents), 0 ].max
    end

    def liquid_balance_required?
      scenario_type.in?(%w[purchase one_time_income extra_debt_payment])
    end

    def setup_status
      @setup_status ||= SetupStatus.new(household)
    end

    def timing_phrase
      effective_on ? " for #{effective_on.strftime('%B %Y')}" : ""
    end

    def money(cents)
      ActionController::Base.helpers.number_to_currency(
        Money.dollars(cents),
        precision: cents.to_i % 100 == 0 ? 0 : 2
      )
    end
  end
end
