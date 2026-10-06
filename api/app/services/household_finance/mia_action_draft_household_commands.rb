module HouseholdFinance
  module MiaActionDraftHouseholdCommands
    SETUP_MONEY_KEYS = %i[
      primary_income business_income fixed_expenses flexible_spend expected_sinking_fund
      unexpected_sinking_fund emergency_fund other_assets
    ].freeze
    SETUP_TEXT_KEYS = %i[household_name primary_goal].freeze
    SETUP_KEYS = (SETUP_TEXT_KEYS + SETUP_MONEY_KEYS + [ :target_runway_months ]).freeze
    SETUP_LABELS = {
      household_name: "Household name",
      primary_goal: "Primary goal",
      primary_income: "Primary monthly income",
      business_income: "Monthly business income",
      fixed_expenses: "Fixed essentials",
      flexible_spend: "Flexible spending",
      expected_sinking_fund: "Expected sinking fund",
      unexpected_sinking_fund: "Unexpected sinking fund",
      emergency_fund: "Emergency fund",
      other_assets: "Other assets",
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

      ambiguous_income = { primary_income: "job", business_income: "business" }.find do |key, source_type|
        requested.key?(key) && household.income_sources.where(source_type: source_type).to_a.count { |source| source.effective_on?(Date.current) } > 1
      end
      if ambiguous_income
        return validation_result("That total includes multiple saved income sources. Name the specific income source you want to change. Nothing changed.")
      end

      normalized = normalize_setup_updates(requested)
      return normalized if normalized.is_a?(MiaActionDraftBuilder::Result)

      before_values = current_setup_values
      confirmed_fields = SetupStatus.new(household).confirmed_field_keys
      changed = normalized.filter_map do |key, value|
        before = normalized_setup_value(key, before_values.fetch(key))
        requires_confirmation = key.in?(SetupStatus::REQUIRED_FIELDS) && !confirmed_fields.include?(key.to_s)
        next if before == value && !requires_confirmation

        [ key, before, value, requires_confirmation ]
      end
      return validation_result("Those household values already match your approved profile, so I did not create a draft.") if changed.empty?

      items = typed_setup_items(changed)
      return items if items.is_a?(MiaActionDraftBuilder::Result)

      impact = setup_impact(before_values, normalized)
      metadata = { source: "mia_chat", parser: "model_intent" }
      metadata[:impact] = impact if impact
      proposal_result(
        draft_type: "household_setup",
        title: changed.one? ? "Update an approved household value" : "Update approved household values",
        summary: "I prepared #{changed.length} household #{'change'.pluralize(changed.length)} for your review.",
        rationale: "These values shape Mia’s coaching and the Home snapshot. They stay unchanged until you approve this card.",
        items: items,
        metadata: metadata
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

      cadence = entry_type == "one_time" ? "one_time" : command[:cadence].presence || "monthly"
      return validation_result("Choose a supported recurring income cadence. Nothing changed.") unless cadence.in?(entry_type == "one_time" ? [ "one_time" ] : IncomeSource::CADENCES - [ "one_time" ])
      amount_cents = Money.cents!(command[:amount], message: "Income amount must be a number")
      return validation_result("One-time income must be greater than $0. Nothing changed.") if entry_type == "one_time" && !amount_cents.positive?
      effective_monthly_cents = entry_type == "one_time" ? nil : Money.period_cents(amount_cents, cadence, month: effective_on.month)

      existing_entry = entry_type == "recurring_change" ? source.income_schedule_entries.find_by(effective_on: effective_on) : nil
      current_source_cents = IncomeTimeline.recurring_monthly_cents(source, on: effective_on)
      if existing_entry && existing_entry.amount_cents == amount_cents && existing_entry.cadence == cadence
        return validation_result("#{source.label} is already scheduled at #{money(amount_cents)} #{income_cadence_label(cadence)} beginning #{effective_on.strftime('%B %Y')}. I did not create a duplicate draft.")
      end

      label = command[:schedule_label].to_s.squish.truncate(80, omission: "…").presence
      item = MiaActionDraftBuilder::Item.new(
        action_type: "upsert_income_schedule_entry",
        label: income_schedule_item_label(source, entry_type, amount_cents, cadence),
        description: income_schedule_description(source, entry_type, current_source_cents, amount_cents, effective_on, cadence),
        target_record_type: existing_entry ? "IncomeScheduleEntry" : "IncomeSource",
        target_record_id: existing_entry&.id || source.id,
        payload: {
          income_source_id: source.id,
          income_source_label: source.label,
          entry_id: existing_entry&.id,
          entry_type: entry_type,
          label: label,
          amount_cents: amount_cents,
          cadence: cadence,
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
          cadence: cadence,
          effective_on: effective_on.iso8601,
          effective_monthly_cents: entry_type == "one_time" ? current_source_cents : effective_monthly_cents
        }
      )
      impact = income_schedule_impact(source, entry_type, current_source_cents, amount_cents, effective_on, cadence)

      proposal_result(
        draft_type: "income_schedule",
        year: effective_on.year,
        title: entry_type == "one_time" ? "Add one-time income" : "Schedule an income change",
        summary: income_schedule_summary(source, entry_type, amount_cents, effective_on, cadence),
        rationale: "The income timeline and future monthly cash-flow view update only after you approve this card.",
        items: [ item ],
        metadata: { source: "mia_chat", parser: "model_intent", impact: impact }
      )
    rescue ArgumentError => e
      validation_result("#{e.message}. Nothing changed.")
    end

    def structured_income_source_create_proposal
      label = command[:income_source_name].to_s.squish.truncate(120, omission: "…")
      return validation_result("Tell me what this income source should be called. Nothing changed.") if label.blank?
      source_type = command[:source_type].to_s.presence_in(IncomeSource::SOURCE_TYPES) || "other"
      cadence = command[:cadence].to_s.presence_in(IncomeSource::CADENCES - [ "one_time" ]) || "monthly"
      starts_on = parsed_effective_month(command[:effective_on])
      return validation_result("Tell me which month this income begins. Nothing changed.") unless starts_on
      amount_cents = Money.cents!(command[:amount], message: "Income amount must be a number")
      item = MiaActionDraftBuilder::Item.new(
        action_type: "create_income_source", label: "Add #{label}",
        description: "Add #{label} at #{money(amount_cents)} #{cadence.humanize.downcase}, beginning #{starts_on.strftime('%B %Y')}.",
        target_record_type: "IncomeSource", target_record_id: nil,
        payload: { label: label, source_type: source_type, amount_cents: amount_cents, cadence: cadence, starts_on: starts_on.iso8601 },
        before_snapshot: {}, after_snapshot: { label: label, source_type: source_type, amount_cents: amount_cents, cadence: cadence, starts_on: starts_on.iso8601 }
      )
      proposal_result(draft_type: "income_schedule", year: starts_on.year, title: "Add income source", summary: "I prepared #{label} for your review.", rationale: "This source changes household income only after approval.", items: [ item ], metadata: { source: "mia_chat", parser: "model_intent" })
    rescue ArgumentError => e
      validation_result("#{e.message}. Nothing changed.")
    end

    def structured_income_source_update_proposal
      source = structured_income_source
      return validation_result("I could not safely match that income source. Nothing changed.") unless source
      payload = { source_id: source.id }
      payload[:label] = command[:new_name].to_s.squish.truncate(120, omission: "…") if command[:new_name].present?
      payload[:source_type] = command[:source_type] if command[:source_type].to_s.in?(IncomeSource::SOURCE_TYPES)
      payload[:amount_cents] = Money.cents!(command[:amount], message: "Income amount must be a number") if command[:amount].present?
      payload[:cadence] = command[:cadence] if command[:cadence].to_s.in?(IncomeSource::CADENCES - [ "one_time" ])
      if command[:effective_on].present?
        starts_on = parsed_effective_month(command[:effective_on])
        return validation_result("Tell me a valid month for this income source. Nothing changed.") unless starts_on
        payload[:starts_on] = starts_on.iso8601
      end
      return validation_result("Tell me which income source detail to update. Nothing changed.") if payload.one?
      item = MiaActionDraftBuilder::Item.new(
        action_type: "update_income_source", label: "Update #{source.label}", description: "Review the exact income-source fields before applying.",
        target_record_type: "IncomeSource", target_record_id: source.id, payload: payload,
        before_snapshot: { label: source.label, source_type: source.source_type, amount_cents: source.amount_cents, cadence: source.cadence, starts_on: source.starts_on&.iso8601 },
        after_snapshot: { label: payload[:label] || source.label, source_type: payload[:source_type] || source.source_type, amount_cents: payload[:amount_cents] || source.amount_cents, cadence: payload[:cadence] || source.cadence, starts_on: payload[:starts_on] || source.starts_on&.iso8601 }
      )
      proposal_result(draft_type: "income_schedule", title: "Update income source", summary: "I prepared an update to #{source.label} for your review.", rationale: "The saved source stays unchanged until approval.", items: [ item ], metadata: { source: "mia_chat", parser: "model_intent" })
    rescue ArgumentError => e
      validation_result("#{e.message}. Nothing changed.")
    end

    def structured_income_source_status_proposal(archive:)
      candidates = household.income_sources.to_a.select do |source|
        if archive
          source.ends_on.blank? && income_source_actionable?(source)
        else
          source.ends_on.present? && source.ends_on >= Date.current.beginning_of_month
        end
      end
      source = if command[:income_source_id].to_i.positive?
        candidates.find { |candidate| candidate.id == command[:income_source_id].to_i }
      else
        normalized_name = command[:income_source_name].to_s.squish.downcase
        matches = candidates.select { |candidate| candidate.label.downcase == normalized_name }
        matches.one? ? matches.first : nil
      end
      return validation_result("I could not safely match that income source. Nothing changed.") unless source
      action = archive ? "archive_income_source" : "restore_income_source"
      payload = { source_id: source.id }
      if archive
        ends_on = parsed_effective_month(command[:effective_on].presence || Date.current.iso8601)
        return validation_result("Tell me the first month when this income should be $0. Nothing changed.") unless ends_on
        ends_on = source.starts_on if source.starts_on&.future? && ends_on <= source.starts_on
        payload[:ends_on] = ends_on.iso8601
      end
      item = MiaActionDraftBuilder::Item.new(
        action_type: action, label: "#{archive ? 'End' : 'Restore'} #{source.label}",
        description: archive ? "$0 beginning #{Date.iso8601(payload.fetch(:ends_on)).strftime('%B %Y')}, while preserving earlier months." : "Restore this source only if its end month has not elapsed.",
        target_record_type: "IncomeSource", target_record_id: source.id, payload: payload,
        before_snapshot: { active: source.active, ends_on: source.ends_on&.iso8601 }, after_snapshot: { active: !archive, ends_on: archive ? payload.fetch(:ends_on) : nil }
      )
      proposal_result(draft_type: "income_schedule", title: "#{archive ? 'End' : 'Restore'} income source", summary: "I prepared #{source.label} for your review.", rationale: "Earlier income history stays intact.", items: [ item ], metadata: { source: "mia_chat", parser: "model_intent" })
    rescue ArgumentError => e
      validation_result("#{e.message}. Nothing changed.")
    end

    def structured_income_schedule_update_proposal
      entry = structured_income_schedule_entry
      return validation_result("I could not safely match that scheduled income entry. Nothing changed.") unless entry
      source = entry.income_source
      effective_on = parsed_effective_month(command[:effective_on].presence || entry.effective_on.iso8601)
      return validation_result("Tell me a valid month for this scheduled income. Nothing changed.") unless effective_on
      type = command[:entry_type].to_s.presence_in(IncomeScheduleEntry::ENTRY_TYPES) || entry.entry_type
      amount_cents = command[:amount].present? ? Money.cents!(command[:amount], message: "Income amount must be a number") : entry.amount_cents
      cadence = type == "one_time" ? "one_time" : command[:cadence].to_s.presence_in(IncomeSource::CADENCES - [ "one_time" ]) || entry.cadence
      payload = { source_id: source.id, entry_id: entry.id, entry_type: type, label: command[:schedule_label].presence || entry.label, amount_cents: amount_cents, cadence: cadence, effective_on: effective_on.iso8601, retained_after_transition: command.key?(:retained_after_transition) ? command[:retained_after_transition] : entry.retained_after_transition? }
      item = MiaActionDraftBuilder::Item.new(action_type: "update_income_schedule_entry", label: "Update scheduled #{source.label}", description: "Review the amount, cadence, and effective month.", target_record_type: "IncomeScheduleEntry", target_record_id: entry.id, payload: payload, before_snapshot: { amount_cents: entry.amount_cents, cadence: entry.cadence, effective_on: entry.effective_on.iso8601 }, after_snapshot: payload.slice(:amount_cents, :cadence, :effective_on))
      proposal_result(draft_type: "income_schedule", year: effective_on.year, title: "Update scheduled income", summary: "I prepared the scheduled #{source.label} change for review.", rationale: "The timeline stays unchanged until approval.", items: [ item ], metadata: { source: "mia_chat", parser: "model_intent" })
    rescue ArgumentError => e
      validation_result("#{e.message}. Nothing changed.")
    end

    def structured_income_schedule_delete_proposal
      entry = structured_income_schedule_entry
      return validation_result("I could not safely match that scheduled income entry. Nothing changed.") unless entry
      source = entry.income_source
      item = MiaActionDraftBuilder::Item.new(action_type: "delete_income_schedule_entry", label: "Remove scheduled #{source.label}", description: "Remove the #{entry.effective_on.strftime('%B %Y')} #{entry.entry_type.humanize.downcase} entry.", target_record_type: "IncomeScheduleEntry", target_record_id: entry.id, payload: { source_id: source.id, entry_id: entry.id }, before_snapshot: { amount_cents: entry.amount_cents, cadence: entry.cadence, effective_on: entry.effective_on.iso8601 }, after_snapshot: {})
      proposal_result(draft_type: "income_schedule", year: entry.effective_on.year, title: "Remove scheduled income", summary: "I prepared one scheduled income entry for removal.", rationale: "No timeline entry is removed until approval.", items: [ item ], metadata: { source: "mia_chat", parser: "model_intent" })
    end

    def structured_income_schedule_entry
      id = command[:income_schedule_entry_id].to_i
      return if id.zero?
      IncomeScheduleEntry.joins(:income_source).where(income_sources: { household_id: household.id }).find_by(id: id)
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

    def typed_setup_items(changes)
      domain_items = []
      changes.each do |key, before, after, _requires_confirmation|
        item = setup_domain_item(key, before, after)
        return item if item.is_a?(MiaActionDraftBuilder::Result)
        if item
          nested_items = item.is_a?(Array) ? item : [ item ]
          offset = domain_items.length
          nested_items.each do |nested|
            nested.dependencies = Array(nested.dependencies).map { |position| position + offset }
          end
          domain_items.concat(nested_items)
        end
      end

      fields = changes.map { |key, _before, _after, _requires_confirmation| key.to_s }
      expected_values = changes.to_h { |key, _before, after, _requires_confirmation| [ key.to_s, after ] }
      confirmation = MiaActionDraftBuilder::Item.new(
        action_type: "confirm_household_setup",
        label: fields.one? ? "Confirm #{SETUP_LABELS.fetch(fields.first.to_sym)}" : "Confirm #{fields.length} starting-picture fields",
        description: "Record only these reviewed fields as confirmed after their typed household changes succeed.",
        target_record_type: "Household", target_record_id: household.id,
        payload: { confirmed_fields: fields, confirm_only_fields: fields, expected_values: expected_values },
        before_snapshot: { confirmed_fields: SetupStatus.new(household).confirmed_field_keys & fields },
        after_snapshot: { confirmed_fields: fields },
        dependencies: (0...domain_items.length).to_a
      )
      domain_items + [ confirmation ]
    end

    def setup_domain_item(key, before, after)
      return if before == after
      return setup_profile_items(key, before, after) if key.in?(SETUP_TEXT_KEYS)
      return setup_income_item(key, after) if key.in?(%i[primary_income business_income])
      return setup_budget_item(key, after) if key.in?(%i[fixed_expenses flexible_spend expected_sinking_fund unexpected_sinking_fund])
      return setup_account_item(key, after) if key.in?(%i[emergency_fund other_assets])
      return setup_runway_item(before, after) if key == :target_runway_months

      validation_result("#{SETUP_LABELS.fetch(key)} needs a supported typed household operation before it can be confirmed. Nothing changed.")
    end

    def setup_profile_items(key, before, after)
      attribute = key == :household_name ? :name : :primary_goal
      items = [ MiaActionDraftBuilder::Item.new(
        action_type: "update_household_profile",
        label: SETUP_LABELS.fetch(key),
        description: setup_value_description(key, before, after, confirmation_only: false),
        target_record_type: "Household", target_record_id: household.id,
        payload: { key: key.to_s, value: after, attribute => after },
        before_snapshot: { key: key.to_s, value: before, display: display_setup_value(key, before) },
        after_snapshot: { key: key.to_s, value: after, display: display_setup_value(key, after) }
      ) ]
      if key == :primary_goal
        items << MiaActionDraftBuilder::Item.new(
          action_type: "update_transition_policy",
          label: "Align the transition goal",
          description: after.to_s.present? ? "Keep the transition goal aligned with the reviewed primary goal." : "Remove the transition goal after clearing the reviewed primary goal.",
          target_record_type: "Goal",
          target_record_id: household.goals.policy.find_by(goal_type: "transition")&.id,
          payload: { label: after },
          before_snapshot: { label: before },
          after_snapshot: { label: after },
          dependencies: [ 0 ]
        )
      end
      items
    end

    def setup_income_item(key, after)
      source_type = key == :primary_income ? "job" : "business"
      label = key == :primary_income ? "Primary income" : "Business income"
      current = household.income_sources.where(source_type: source_type).to_a.select { |source| source.effective_on?(Date.current) }
      return validation_result("#{label} has multiple saved sources. Edit a specific income source so no detailed amount changes silently. Nothing changed.") if current.many?
      return if current.empty? && Money.cents(after).zero?

      command = if current.one?
        {
          type: "schedule_income_change", income_source_id: current.first.id, income_source_name: current.first.label,
          entry_type: "recurring_change", amount: after.to_s, effective_on: Date.current.beginning_of_month.iso8601
        }
      else
        {
          type: "create_income_source", income_source_name: label, source_type: source_type,
          amount: after.to_s, cadence: "monthly", effective_on: Date.current.beginning_of_month.iso8601
        }
      end
      setup_item_from_command(command)
    end

    def setup_budget_item(key, after)
      label, stack_key = {
        fixed_expenses: [ "Fixed essentials", "non_discretionary" ],
        flexible_spend: [ "Flexible spending", "discretionary" ],
        expected_sinking_fund: [ "Expected sinking fund", "sinking_expected" ],
        unexpected_sinking_fund: [ "Unexpected sinking fund", "sinking_unexpected" ]
      }.fetch(key)
      categories = household.budget_categories.active.where(stack_key: stack_key).order(:id).to_a
      if categories.many?
        return validation_result("#{SETUP_LABELS.fetch(key)} is tracked by multiple budget categories. Edit the specific categories so detailed planned dollars do not change silently. Nothing changed.")
      end

      command = if categories.one?
        { type: "set_allocation", category_id: categories.first.id, category_name: categories.first.name, amount: after.to_s, months: (1..12).to_a, year: annual_budget_manager.year }
      else
        { type: "create_category", new_name: label, stack_key: stack_key, amount: after.to_s, months: (1..12).to_a, year: annual_budget_manager.year }
      end
      setup_item_from_command(command)
    end

    def setup_account_item(key, after)
      label, account_type = key == :emergency_fund ? [ "Emergency fund", "emergency_fund" ] : [ "Other assets", "other" ]
      accounts = household.accounts.active.where(account_type: account_type).order(:id).to_a
      if accounts.many?
        return validation_result("#{SETUP_LABELS.fetch(key)} is tracked by multiple accounts. Edit a specific account so detailed balances do not change silently. Nothing changed.")
      end
      command = if accounts.one?
        { type: "update_account", account_id: accounts.first.id, account_name: accounts.first.label, amount: after.to_s, balance_as_of_on: Date.current.iso8601 }
      else
        { type: "create_account", account_name: label, account_type: account_type, amount: after.to_s, balance_as_of_on: Date.current.iso8601 }
      end
      setup_item_from_command(command)
    end

    def setup_runway_item(before, after)
      MiaActionDraftBuilder::Item.new(
        action_type: "update_runway_policy", label: "Update runway target",
        description: setup_value_description(:target_runway_months, before, after, confirmation_only: false),
        target_record_type: "Goal", target_record_id: household.goals.policy.find_by(goal_type: "runway")&.id,
        payload: { target_months: after.to_s },
        before_snapshot: { target_months: before }, after_snapshot: { target_months: after }
      )
    end

    def setup_item_from_command(nested_command)
      result = MiaActionDraftBuilder.new(
        household,
        user: user,
        annual_budget_manager: annual_budget_manager,
        selected_month: selected_month,
        raw_input: raw_input,
        command: nested_command
      ).call
      return result if result&.proposal.nil?
      return validation_result("That starting-picture value expanded into an unsafe review. Nothing changed.") unless result.proposal.items.one?

      result.proposal.items.first
    end

    def setup_value_description(key, before, after, confirmation_only:)
      return "Confirm #{display_setup_value(key, after)} as your #{SETUP_LABELS.fetch(key).downcase}." if confirmation_only

      "#{display_setup_value(key, before)} → #{display_setup_value(key, after)}"
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
      return unless setup_impact_matches_current_plan?(before_values, before_income, before_outflow)

      {
        scope: "Current monthly snapshot",
        before_monthly_income: before_income,
        after_monthly_income: after_income,
        before_monthly_outflow: before_outflow,
        after_monthly_outflow: after_outflow,
        before_baseline_surplus: money_difference(before_income, before_outflow),
        after_baseline_surplus: money_difference(after_income, after_outflow)
      }
    end

    # Setup fields cover only the starting-picture records. A global preview
    # is truthful only when those fields reconcile with the current saved plan.
    def setup_impact_matches_current_plan?(values, before_income, before_outflow)
      today = Date.current
      return false unless annual_budget_manager.year == today.year

      plan = AnnualBudgetManager.new(household, year: today.year).read_only_plan_data
      return false unless plan.fetch(:plan_available)
      period = plan.fetch(:months).find { |month| Date.iso8601(month.fetch(:starts_on)).month == today.month }
      return false unless period && before_income
      snapshot = SnapshotBuilder.new(household, reference_date: today, ensure_plan: false).call
      income_cents = Money.cents(before_income)
      return false unless income_cents == snapshot.fetch(:monthly_income_cents) && income_cents == Money.cents(plan.fetch(:monthly_income).fetch(period.fetch(:id)))

      rows = plan.fetch(:rows).select { |row| row.fetch(:active) }
      return false if rows.any? { |row| row.fetch(:months).fetch(today.month - 1).fetch(:allocation_missing) }
      stacks = { fixed_expenses: "non_discretionary", flexible_spend: "discretionary", expected_sinking_fund: "sinking_expected", unexpected_sinking_fund: "sinking_unexpected" }
      return false unless stacks.all? do |key, stack|
        planned = rows.select { |row| row.fetch(:stack_key) == stack }.sum { |row| Money.cents(row.fetch(:months).fetch(today.month - 1).fetch(:planned)) }
        values[key] && Money.cents(values[key]) == planned && planned == snapshot.fetch(:stack_totals_cents).fetch(stack)
      end
      return !snapshot.fetch(:debt_minimums_known) && !plan.fetch(:monthly_debt_minimums_known) if before_outflow.nil?
      return false unless snapshot.fetch(:debt_minimums_known) && plan.fetch(:monthly_debt_minimums_known)

      planned_outflow = rows.sum { |row| Money.cents(row.fetch(:months).fetch(today.month - 1).fetch(:planned)) } + Money.cents(plan.fetch(:monthly_debt_minimums))
      Money.cents(before_outflow) == snapshot.fetch(:total_outflow_cents) && Money.cents(before_outflow) == planned_outflow
    end

    def setup_money_total(values, *keys)
      amounts = keys.map { |key| values.fetch(key, 0) }
      return if amounts.any?(&:nil?)

      Money.dollars(amounts.sum { |value| Money.cents(value) })
    end

    def structured_income_source
      candidates = household.income_sources.to_a.select { |source| income_source_actionable?(source) }
      id = command[:income_source_id].to_i
      return candidates.find { |source| source.id == id } if id.positive?

      name = command[:income_source_name].to_s.squish
      return if name.blank?

      matches = candidates.select { |source| source.label.casecmp?(name) }.first(2)
      matches.one? ? matches.first : nil
    end

    def income_source_actionable?(source)
      source.timeline_status(on: Date.current).in?(%w[current future])
    end

    def parsed_effective_month(value)
      Date.iso8601(value.to_s).beginning_of_month
    rescue Date::Error
      nil
    end

    def income_cadence_label(cadence)
      { "monthly" => "per month", "weekly" => "per week", "biweekly" => "every two weeks", "semi_monthly" => "twice a month", "annual" => "per year" }.fetch(cadence)
    end

    def income_schedule_item_label(source, entry_type, amount_cents, cadence = "monthly")
      return "Add #{money(amount_cents)} of one-time #{source.label}" if entry_type == "one_time"

      "Set #{source.label} to #{money(amount_cents)} #{income_cadence_label(cadence)}"
    end

    def income_schedule_description(source, entry_type, current_cents, amount_cents, effective_on, cadence = "monthly")
      month = effective_on.strftime("%B %Y")
      return "Add #{money(amount_cents)} to #{month}; the recurring #{source.label} amount remains #{money(current_cents)} per month." if entry_type == "one_time"

      return "Beginning #{month}: #{money(current_cents)} → #{money(amount_cents)} per month." if cadence == "monthly"

      monthly = Money.period_cents(amount_cents, cadence, month: effective_on.month)
      "Beginning #{month}: #{money(amount_cents)} #{income_cadence_label(cadence)}; the monthly planning equivalent changes from #{money(current_cents)} to #{money(monthly)}."
    end

    def income_schedule_summary(source, entry_type, amount_cents, effective_on, cadence = "monthly")
      month = effective_on.strftime("%B %Y")
      return "I prepared adding #{money(amount_cents)} of one-time #{source.label} in #{month}." if entry_type == "one_time"

      "I prepared setting #{source.label} to #{money(amount_cents)} #{income_cadence_label(cadence)} beginning #{month}."
    end

    def income_schedule_impact(source, entry_type, current_source_cents, amount_cents, effective_on, cadence = "monthly")
      plan = AnnualBudgetManager.new(household, year: effective_on.year).read_only_plan_data.deep_symbolize_keys
      return unless plan.fetch(:plan_available)

      period = Array(plan[:months]).find { |month| Date.iso8601(month.fetch(:starts_on)).month == effective_on.month }
      before_income_cents = period ? Money.cents(plan.fetch(:monthly_income).fetch(period.fetch(:id))) : 0
      source_delta_cents = entry_type == "one_time" ? amount_cents : Money.period_cents(amount_cents, cadence, month: effective_on.month) - current_source_cents
      outflow_cents = if plan.fetch(:monthly_debt_minimums_known)
        plan.fetch(:rows).sum { |row| Money.cents(row.fetch(:months).fetch(effective_on.month - 1).fetch(:planned)) } + Money.cents(plan.fetch(:monthly_debt_minimums))
      end
      after_income_cents = before_income_cents + source_delta_cents
      {
        scope: effective_on.strftime("%B %Y"),
        before_monthly_income: Money.dollars(before_income_cents),
        after_monthly_income: Money.dollars(after_income_cents),
        before_monthly_outflow: outflow_cents && Money.dollars(outflow_cents),
        after_monthly_outflow: outflow_cents && Money.dollars(outflow_cents),
        before_baseline_surplus: outflow_cents && Money.dollars(before_income_cents - outflow_cents),
        after_baseline_surplus: outflow_cents && Money.dollars(after_income_cents - outflow_cents)
      }
    end

    def money_difference(minuend, subtrahend)
      return if minuend.nil? || subtrahend.nil?

      Money.dollars(Money.cents(minuend) - Money.cents(subtrahend))
    end
  end
end
