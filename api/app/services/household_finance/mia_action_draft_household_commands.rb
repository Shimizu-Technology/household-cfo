module HouseholdFinance
  module MiaActionDraftHouseholdCommands
    SETUP_MONEY_KEYS = %i[
      primary_income business_income emergency_fund other_assets credit_card_debt debt_payment
    ].freeze
    SETUP_TEXT_KEYS = %i[household_name primary_goal].freeze
    SETUP_KEYS = (SETUP_TEXT_KEYS + SETUP_MONEY_KEYS + [ :target_runway_months ]).freeze
    SETUP_LABELS = {
      household_name: "Household name",
      primary_goal: "Primary goal",
      primary_income: "Primary monthly income",
      business_income: "Monthly business income",
      emergency_fund: "Emergency fund",
      other_assets: "Other assets",
      credit_card_debt: "Credit card debt",
      debt_payment: "Monthly debt minimum",
      target_runway_months: "Runway target"
    }.freeze

    def self.recurring_schedule_snapshot(source, effective_on)
      source.income_schedule_entries
        .select { |entry| entry.entry_type == "recurring_change" && entry.effective_on <= effective_on.end_of_month }
        .sort_by { |entry| [ entry.effective_on, entry.id ] }
        .map do |entry|
          {
            id: entry.id,
            amount_cents: entry.amount_cents,
            cadence: entry.cadence,
            effective_on: entry.effective_on.iso8601
          }
        end
    end

    private

    def structured_household_setup_proposal
      requested = command.fetch(:setup_updates, {}).to_h.symbolize_keys.slice(*SETUP_KEYS)
        .select { |_key, value| value.to_s.strip.present? }
      return validation_result("Tell me which household number or goal you want to update. Nothing changed.") if requested.empty?

      normalized = normalize_setup_updates(requested)
      return normalized if normalized.is_a?(MiaActionDraftBuilder::Result)

      before_values = current_setup_values
      items = normalized.filter_map do |key, value|
        before = normalized_setup_value(key, before_values.fetch(key))
        next if before == value

        setup_value_item(key, before, value)
      end
      return validation_result("Those household values already match your approved profile, so I did not create a draft.") if items.empty?

      impact = setup_impact(before_values, normalized)
      proposal_result(
        draft_type: "household_setup",
        title: items.one? ? "Update an approved household number" : "Update approved household numbers",
        summary: "I prepared #{items.length} household #{'change'.pluralize(items.length)} for your review.",
        rationale: "These values shape Mia’s coaching and the Home snapshot. They stay unchanged until you approve this card.",
        items: items,
        metadata: { source: "mia_chat", parser: "model_intent", impact: impact }
      )
    end

    def structured_income_schedule_proposal
      source = structured_income_source
      return validation_result("I could not match that request to an active income source. Name the job or business income you want to change. Nothing changed.") unless source

      entry_type = command[:entry_type].to_s
      return validation_result("Tell me whether this is a continuing income change or one-time income. Nothing changed.") unless entry_type.in?(IncomeScheduleEntry::ENTRY_TYPES)

      effective_on = parsed_effective_month(command[:effective_on])
      return validation_result("Tell me the month when this income change starts. Nothing changed.") unless effective_on
      return validation_result("That income date is outside the supported planning range. Nothing changed.") unless AnnualBudgetManager.supported_year?(effective_on.year)

      amount_cents = Money.cents!(command[:amount], message: "Income amount must be a number")
      return validation_result("One-time income must be greater than $0. Nothing changed.") if entry_type == "one_time" && !amount_cents.positive?

      existing_entry = entry_type == "recurring_change" ? source.income_schedule_entries.find_by(effective_on: effective_on) : nil
      current_source_cents = IncomeTimeline.recurring_monthly_cents(source, on: effective_on)
      if existing_entry && existing_entry.amount_cents == amount_cents && existing_entry.cadence == "monthly"
        return validation_result("#{source.label} is already scheduled at #{money(amount_cents)} per month beginning #{effective_on.strftime('%B %Y')}. I did not create a duplicate draft.")
      end

      label = command[:schedule_label].to_s.squish.truncate(80, omission: "…").presence
      item = MiaActionDraftBuilder::Item.new(
        action_type: "upsert_income_schedule_entry",
        label: income_schedule_item_label(source, entry_type, amount_cents),
        description: income_schedule_description(source, entry_type, current_source_cents, amount_cents, effective_on),
        target_record_type: existing_entry ? "IncomeScheduleEntry" : "IncomeSource",
        target_record_id: existing_entry&.id || source.id,
        payload: {
          income_source_id: source.id,
          income_source_label: source.label,
          entry_id: existing_entry&.id,
          entry_type: entry_type,
          label: label,
          amount_cents: amount_cents,
          cadence: entry_type == "one_time" ? "one_time" : "monthly",
          effective_on: effective_on.iso8601
        },
        before_snapshot: {
          income_source_id: source.id,
          income_source_label: source.label,
          income_source_amount_cents: source.amount_cents,
          income_source_cadence: source.cadence,
          recurring_schedule_entries: MiaActionDraftHouseholdCommands.recurring_schedule_snapshot(source, effective_on),
          entry_id: existing_entry&.id,
          amount_cents: existing_entry&.amount_cents,
          cadence: existing_entry&.cadence,
          effective_on: effective_on.iso8601,
          effective_monthly_cents: current_source_cents
        },
        after_snapshot: {
          income_source_id: source.id,
          income_source_label: source.label,
          entry_id: existing_entry&.id,
          amount_cents: amount_cents,
          cadence: entry_type == "one_time" ? "one_time" : "monthly",
          effective_on: effective_on.iso8601,
          effective_monthly_cents: entry_type == "one_time" ? current_source_cents : amount_cents
        }
      )
      impact = income_schedule_impact(source, entry_type, current_source_cents, amount_cents, effective_on)

      proposal_result(
        draft_type: "income_schedule",
        year: effective_on.year,
        title: entry_type == "one_time" ? "Add one-time income" : "Schedule an income change",
        summary: income_schedule_summary(source, entry_type, amount_cents, effective_on),
        rationale: "The income timeline and future monthly cash-flow view update only after you approve this card.",
        items: [ item ],
        metadata: { source: "mia_chat", parser: "model_intent", impact: impact }
      )
    rescue ArgumentError => e
      validation_result("#{e.message}. Nothing changed.")
    end

    def normalize_setup_updates(requested)
      requested.each_with_object({}) do |(key, raw_value), values|
        values[key] = if SETUP_MONEY_KEYS.include?(key)
          Money.dollars(Money.cents!(raw_value, message: "#{SETUP_LABELS.fetch(key)} must be a number"))
        elsif key == :target_runway_months
          months = BigDecimal(raw_value.to_s)
          return validation_result("Runway target must be greater than 0 and no more than 120 months. Nothing changed.") unless months.positive? && months <= 120

          months.to_f
        else
          limit = key == :primary_goal ? 500 : 120
          raw_value.to_s.squish.truncate(limit, omission: "…")
        end
      end
    rescue ArgumentError => e
      validation_result("#{e.message}. Nothing changed.")
    end

    def current_setup_values
      DataPresenter.new(household, user: user, annual_plan: annual_plan).setup_values.deep_symbolize_keys
    end

    def normalized_setup_value(key, value)
      return value.to_f if SETUP_MONEY_KEYS.include?(key) || key == :target_runway_months

      value.to_s.squish
    end

    def setup_value_item(key, before, after)
      MiaActionDraftBuilder::Item.new(
        action_type: "update_setup_value",
        label: SETUP_LABELS.fetch(key),
        description: "#{display_setup_value(key, before)} → #{display_setup_value(key, after)}",
        target_record_type: "Household",
        target_record_id: household.id,
        payload: { key: key.to_s, value: after },
        before_snapshot: { key: key.to_s, value: before, display: display_setup_value(key, before) },
        after_snapshot: { key: key.to_s, value: after, display: display_setup_value(key, after) }
      )
    end

    def display_setup_value(key, value)
      return ActionController::Base.helpers.number_to_currency(value.to_f) if SETUP_MONEY_KEYS.include?(key)
      return "#{value.to_f.round(1)} months" if key == :target_runway_months

      value.to_s.presence || "Not set"
    end

    def setup_impact(before_values, normalized)
      after_values = before_values.merge(normalized)
      before_income = setup_money_total(before_values, :primary_income, :business_income)
      after_income = setup_money_total(after_values, :primary_income, :business_income)
      before_outflow = setup_money_total(before_values, :fixed_expenses, :flexible_spend, :expected_sinking_fund, :unexpected_sinking_fund, :debt_payment)
      after_outflow = setup_money_total(after_values, :fixed_expenses, :flexible_spend, :expected_sinking_fund, :unexpected_sinking_fund, :debt_payment)
      {
        scope: "Current monthly snapshot",
        before_monthly_income: before_income,
        after_monthly_income: after_income,
        before_monthly_outflow: before_outflow,
        after_monthly_outflow: after_outflow,
        before_baseline_surplus: before_income - before_outflow,
        after_baseline_surplus: after_income - after_outflow
      }
    end

    def setup_money_total(values, *keys)
      keys.sum { |key| values.fetch(key, 0).to_f }
    end

    def structured_income_source
      scope = household.income_sources.where(active: true)
      id = command[:income_source_id].to_i
      return scope.find_by(id: id) if id.positive?

      name = command[:income_source_name].to_s.squish
      return if name.blank?

      scope.where("LOWER(label) = ?", name.downcase).first
    end

    def parsed_effective_month(value)
      Date.iso8601(value.to_s).beginning_of_month
    rescue Date::Error
      nil
    end

    def income_schedule_item_label(source, entry_type, amount_cents)
      return "Add #{money(amount_cents)} of one-time #{source.label}" if entry_type == "one_time"

      "Set #{source.label} to #{money(amount_cents)} per month"
    end

    def income_schedule_description(source, entry_type, current_cents, amount_cents, effective_on)
      month = effective_on.strftime("%B %Y")
      return "Add #{money(amount_cents)} to #{month}; the recurring #{source.label} amount remains #{money(current_cents)} per month." if entry_type == "one_time"

      "Beginning #{month}: #{money(current_cents)} → #{money(amount_cents)} per month."
    end

    def income_schedule_summary(source, entry_type, amount_cents, effective_on)
      month = effective_on.strftime("%B %Y")
      return "I prepared adding #{money(amount_cents)} of one-time #{source.label} in #{month}." if entry_type == "one_time"

      "I prepared setting #{source.label} to #{money(amount_cents)} per month beginning #{month}."
    end

    def income_schedule_impact(source, entry_type, current_source_cents, amount_cents, effective_on)
      plan = AnnualBudgetManager.new(household, year: effective_on.year).plan_data.deep_symbolize_keys
      period = Array(plan[:months]).find { |month| Date.iso8601(month.fetch(:starts_on)).month == effective_on.month }
      before_income = period ? plan.fetch(:monthly_income).fetch(period.fetch(:id)).to_f : 0
      source_delta = entry_type == "one_time" ? Money.dollars(amount_cents) : Money.dollars(amount_cents - current_source_cents)
      outflow = plan.fetch(:rows).sum { |row| row.fetch(:months).fetch(effective_on.month - 1).fetch(:planned).to_f } + plan.fetch(:monthly_debt_minimums).to_f
      {
        scope: effective_on.strftime("%B %Y"),
        before_monthly_income: before_income,
        after_monthly_income: before_income + source_delta,
        before_monthly_outflow: outflow,
        after_monthly_outflow: outflow,
        before_baseline_surplus: before_income - outflow,
        after_baseline_surplus: before_income + source_delta - outflow
      }
    end
  end
end
