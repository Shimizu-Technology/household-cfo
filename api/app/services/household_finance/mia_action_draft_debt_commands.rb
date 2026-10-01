module HouseholdFinance
  module MiaActionDraftDebtCommands
    private

    def structured_debt_create_proposal
      label = command[:debt_name].to_s.squish.truncate(120, omission: "…")
      return validation_result("Tell me what this debt should be called. Nothing changed.") if label.blank?
      debt_type = command[:debt_type].to_s.presence_in(::Debt::DEBT_TYPES) || "other"
      if household.debts.active.where(debt_type: debt_type).where("LOWER(label) = ?", label.downcase).exists?
        return validation_result("An active debt already uses that name and type. Tell me which detail to update. Nothing changed.")
      end
      payload = { label: label, debt_type: debt_type, source_type: "mia" }
      add_debt_money_value!(payload, debt_balance_command_value, :balance_cents, :balance_known)
      add_debt_money_payload!(payload, :minimum_payment, :minimum_payment_cents, :minimum_payment_known)
      payload[:interest_rate_percent] = parsed_debt_apr(command[:interest_rate_percent]) if command.key?(:interest_rate_percent)
      item = MiaActionDraftBuilder::Item.new(
        action_type: "create_debt", label: "Add #{label}",
        description: "Add an approved debt record. Any blank balance, minimum, or APR stays marked as unknown.",
        target_record_type: "Debt", target_record_id: nil, payload: payload,
        before_snapshot: {}, after_snapshot: payload.merge(active: true)
      )
      proposal_result(draft_type: "debt_plan", title: "Add debt", summary: "I prepared #{label} for your review.", rationale: individual_debt_change_rationale("be added", "This record affects planning only after you apply it. No payment is made."), items: [ item ], metadata: { source: "mia_chat", parser: "model_intent" })
    rescue ArgumentError => e
      validation_result("#{e.message}. Nothing changed.")
    end

    def structured_debt_update_proposal
      debt = structured_debt(active: true)
      return validation_result("I could not safely match that active debt. Name it exactly or choose it by id. Nothing changed.") unless debt
      payload = { debt_id: debt.id }
      payload[:label] = command[:new_name].to_s.squish.truncate(120, omission: "…") if command[:new_name].present?
      payload[:debt_type] = command[:debt_type] if command[:debt_type].to_s.in?(::Debt::DEBT_TYPES)
      add_debt_money_value!(payload, debt_balance_command_value, :balance_cents, :balance_known) if debt_balance_command_present?
      add_debt_money_payload!(payload, :minimum_payment, :minimum_payment_cents, :minimum_payment_known) if command.key?(:minimum_payment)
      payload[:interest_rate_percent] = parsed_debt_apr(command[:interest_rate_percent]) if command.key?(:interest_rate_percent)
      return validation_result("Tell me which debt detail to update. Nothing changed.") if payload.one?
      before = debt_action_snapshot(debt)
      after = before.merge(payload.except(:debt_id))
      item = MiaActionDraftBuilder::Item.new(
        action_type: "update_debt", label: "Update #{debt.label}", description: "Review each changed debt field before applying.",
        target_record_type: "Debt", target_record_id: debt.id, payload: payload,
        before_snapshot: before, after_snapshot: after
      )
      proposal_result(draft_type: "debt_plan", title: "Update debt", summary: "I prepared an update to #{debt.label} for your review.", rationale: individual_debt_change_rationale("be updated", "The approved record stays unchanged until you apply this card."), items: [ item ], metadata: { source: "mia_chat", parser: "model_intent" })
    rescue ArgumentError => e
      validation_result("#{e.message}. Nothing changed.")
    end

    def structured_debt_status_proposal(archive:)
      debt = structured_debt(active: !archive ? false : true)
      return validation_result("I could not safely match that #{archive ? 'active' : 'archived'} debt. Name it exactly or choose it by id. Nothing changed.") unless debt
      action = archive ? "archive_debt" : "restore_debt"
      item = MiaActionDraftBuilder::Item.new(
        action_type: action, label: "#{archive ? 'Archive' : 'Restore'} #{debt.label}",
        description: archive ? "Remove this debt from active planning while preserving its history." : "Return this debt to active planning without creating a duplicate.",
        target_record_type: "Debt", target_record_id: debt.id, payload: { debt_id: debt.id },
        before_snapshot: debt_action_snapshot(debt), after_snapshot: debt_action_snapshot(debt).merge(active: !archive)
      )
      proposal_result(draft_type: "debt_plan", title: "#{archive ? 'Archive' : 'Restore'} debt", summary: "I prepared #{debt.label} for your review.", rationale: individual_debt_change_rationale(archive ? "be archived" : "be restored", "History remains preserved and nothing changes until approval."), items: [ item ], metadata: { source: "mia_chat", parser: "model_intent" })
    end

    def structured_debt_tracking_proposal
      mode = command[:debt_tracking_mode].to_s
      return validation_result("Choose summary or individual debt tracking. Nothing changed.") unless mode.in?(HouseholdProfile::DEBT_TRACKING_MODES)
      portfolio = DebtPortfolio.new(household)
      payload = { mode: mode }
      if mode == "summary"
        unless debt_balance_command_present? && command.key?(:minimum_payment)
          return validation_result("Tell me the total balance and total monthly minimum. Use “unknown” for either value you have not confirmed. Nothing changed.")
        end
        add_debt_money_value!(payload, debt_balance_command_value, :summary_balance_cents, :summary_balance_known)
        add_debt_money_payload!(payload, :minimum_payment, :summary_minimum_payment_cents, :summary_minimum_payment_known)
      end
      item = MiaActionDraftBuilder::Item.new(
        action_type: "update_debt_tracking", label: "Use #{mode} debt tracking",
        description: mode == "summary" ? "Use only the approved household totals for planning." : "Use only active individual debt records for planning.",
        target_record_type: "HouseholdProfile", target_record_id: household.household_profile.id,
        payload: payload, before_snapshot: portfolio.as_json, after_snapshot: portfolio.as_json.merge(mode: mode)
      )
      proposal_result(draft_type: "debt_plan", title: "Change debt tracking", summary: "I prepared switching debt tracking from #{portfolio.mode} to #{mode}.", rationale: "The two sources are never added together, and saved records stay preserved.", items: [ item ], metadata: { source: "mia_chat", parser: "model_intent" })
    rescue ArgumentError => e
      validation_result("#{e.message}. Nothing changed.")
    end

    def structured_debt(active:)
      scope = household.debts.where(active: active)
      return scope.find_by(id: command[:debt_id].to_i) if command[:debt_id].to_i.positive?
      name = command[:debt_name].to_s.squish
      return if name.blank?
      matches = scope.where("LOWER(label) = ?", name.downcase).to_a
      matches.one? ? matches.first : nil
    end

    def individual_debt_change_rationale(change, individual_mode_copy)
      return individual_mode_copy unless DebtPortfolio.new(household).mode == "summary"

      "After approval, the preserved individual record will #{change}, but the approved household summary will continue to drive totals and readiness until you explicitly switch to individual tracking. No payment is made."
    end

    def add_debt_money_payload!(payload, command_key, cents_key, known_key)
      add_debt_money_value!(payload, command[command_key], cents_key, known_key, label: command_key)
    end

    def add_debt_money_value!(payload, value, cents_key, known_key, label: :balance)
      if value.nil? || value.to_s.strip.blank? || value.to_s.casecmp("unknown").zero?
        payload[cents_key] = 0
        payload[known_key] = false
      else
        payload[cents_key] = Money.cents!(value, message: label.to_s.humanize + " must be a number")
        payload[known_key] = true
      end
    end

    def debt_balance_command_value
      command.key?(:balance) ? command[:balance] : command[:amount]
    end

    def debt_balance_command_present?
      command.key?(:balance) || command[:amount].present?
    end

    def parsed_debt_apr(value)
      return nil if value.nil? || value.to_s.strip.blank? || value.to_s.casecmp("unknown").zero?
      decimal = BigDecimal(value.to_s)
      raise ArgumentError, "APR must be between 0 and 999.99" unless decimal.between?(0, 999.99)
      decimal.to_f
    end

    def debt_action_snapshot(debt)
      {
        id: debt.id, label: debt.label, debt_type: debt.debt_type,
        balance_cents: debt.balance_cents, balance_known: debt.balance_known?,
        minimum_payment_cents: debt.minimum_payment_cents, minimum_payment_known: debt.minimum_payment_known?,
        interest_rate_percent: debt.interest_rate_percent&.to_f,
        active: debt.active?, archived_at: debt.archived_at&.iso8601,
        source_type: debt.source_type, source_metadata: debt.source_metadata
      }
    end
  end
end
