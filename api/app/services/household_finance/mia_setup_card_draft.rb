module HouseholdFinance
  # Turns the card into the same typed items a single-field review would use,
  # so Apply keeps its prepared operations, stale checks and audit trail.
  class MiaSetupCardDraft
    def initialize(household, user:, card:, annual_budget_manager: AnnualBudgetManager.new(household, year: Date.current.year))
      @household = household
      @user = user
      @card = card
      @annual_budget_manager = annual_budget_manager
    end

    def save!(user_message:, assistant_message:, existing:)
      proposal = build_proposal(source_prompt: user_message&.content)
      if existing
        proposal.sync_items!(existing)
        existing.reload
      else
        proposal.create_draft!(source_chat_message: user_message, assistant_chat_message: assistant_message, allow_empty: true)
      end
    end

    def sync!(draft)
      build_proposal(source_prompt: draft.source_prompt).sync_items!(draft)
      draft.reload
    end

    # A partial Apply saves what is counted; the rows still waiting on an amount
    # move to a fresh card so she can finish them.
    def self.carry_unresolved!(draft, user:, source_message:)
      state = draft.metadata.to_h["setup_card"]
      return unless state && source_message
      remaining = MiaSetupCard.new(draft.household, state: state).unresolved_state
      return if remaining["fields"].empty?
      card = MiaSetupCard.new(draft.household.reload, state: remaining)
      card.rebase_all
      new(draft.household, user: user, card: card).save!(user_message: source_message, assistant_message: draft.assistant_chat_message, existing: nil)
    end

    private

    def build_items
      blocked = {}
      items = setup_items(blocked)
      items.concat(debt_items(blocked))
      [ blocked, items ]
    end

    def build_proposal(source_prompt:)
      blocked, items = build_items
      MiaActionDraftBuilder::Proposal.new(household: household, user: user, year: Date.current.year,
        draft_type: "household_setup", title: title, summary: title, rationale: "", source_prompt: source_prompt,
        items: items, metadata: { source: "mia_chat", parser: "setup_card", setup_card: card.to_h.merge("blocked" => blocked, "revision" => card.revision + 1, "change_mode" => change_mode?) }.merge(card.spending_preferences.any? ? { spending_preferences: card.spending_preferences } : {}))
    end

    attr_reader :household, :user, :card

    # Once setup is done the same card only carries changes.
    def change_mode? = @change_mode.nil? ? (@change_mode = card.to_h["change_mode"] || SetupStatus.new(household).settled?) : @change_mode
    def title = change_mode? ? MiaSetupCardTurn::CHANGE_TITLE : MiaSetupCardTurn::TITLE

    # One reviewed setup change for every whole value and named bill. If one
    # field can't be prepared, the rest still can, and that row says why.
    def setup_items(blocked)
      updates = card.setup_updates
      bills = card.bill_changes
      return [] if updates.empty? && bills.empty?
      result = setup_builder(updates, bills)
      return result.proposal.items if result&.proposal

      fields = updates.keys.map(&:to_s) + bills.keys
      workable = fields.select do |field|
        single = setup_builder(updates.slice(field.to_sym), bills.slice(field))
        next true if single&.proposal
        blocked[field] = single&.response.to_s unless single&.response.to_s.start_with?("Those household values")
        false
      end
      return [] if workable.empty?
      setup_builder(updates.slice(*workable.map(&:to_sym)), bills.slice(*workable))&.proposal&.items.to_a
    end

    def setup_builder(updates, bills)
      builder(type: "update_household_setup", setup_updates: updates, setup_bills: bills, spending_preferences: card.spending_preferences.presence)
    end

    def debt_items(blocked)
      state = card.debt_state
      return debt_balance_items(blocked) if state.empty? || !card.debts_changed?
      commands = if state["none"]
        [ { type: "update_debt_tracking", debt_tracking_mode: "summary", amount: "0", minimum_payment: "0" } ]
      elsif state["total_cents"]
        portfolio = DebtPortfolio.new(household)
        [ { type: "update_debt_tracking", debt_tracking_mode: "summary", amount: portfolio.balance_known? ? portfolio.total_balance_cents.fdiv(100).to_s : "unknown", minimum_payment: Money.dollars(state["total_cents"]).to_s } ]
      else
        named_debt_commands(state)
      end
      commands.flat_map do |command|
        result = builder(**command)
        next result.proposal.items if result&.proposal
        blocked[MiaSetupCard::DEBT_FIELD] = result&.response.to_s
        []
      end
    end

    # The total owed, when debts are kept as one summary rather than one by one.
    def debt_balance_items(blocked)
      cents = card.debt_balance_cents
      return [] unless cents && !card.stale?("credit_card_debt")
      portfolio = DebtPortfolio.new(household)
      if portfolio.mode == "individual" && portfolio.active_debts.any?
        blocked["credit_card_debt"] = "Your debts are saved one by one, so tell me which debt's balance changed."
        return []
      end
      result = builder(type: "update_debt_tracking", debt_tracking_mode: "summary", amount: Money.dollars(cents).to_s,
        minimum_payment: portfolio.minimum_payment_known? ? Money.dollars(portfolio.monthly_minimum_cents).to_s : "unknown")
      return result.proposal.items if result&.proposal
      blocked["credit_card_debt"] = result&.response.to_s
      []
    end

    def named_debt_commands(state)
      parts = Array(state["parts"]).reject { |part| part["placeholder"] }
      commands = parts.filter_map do |part|
        if part["removed"]
          { type: "archive_debt", debt_id: part["debt_id"] } if part["debt_id"]
        elsif part["saved"]
          next unless part["changed"]
          debt_update_command(part)
        else
          { type: "create_debt", debt_name: part["name"], debt_type: debt_type(part["name"]),
            minimum_payment: money_value(part["minimum_cents"]), balance: money_value(part["balance_cents"]) }
        end
      end
      commands << { type: "update_debt_tracking", debt_tracking_mode: "individual" } if commands.any? && DebtPortfolio.new(household).mode == "summary"
      commands
    end

    def debt_update_command(part)
      command = { type: "update_debt", debt_id: part["debt_id"] }
      command[:minimum_payment] = Money.dollars(part["minimum_cents"]).to_s if part["minimum_cents"]
      command[:balance] = Money.dollars(part["balance_cents"]).to_s if part["balance_cents"]
      command
    end

    def money_value(cents) = cents.nil? ? "unknown" : Money.dollars(cents).to_s

    def debt_type(name)
      case name.to_s
      when /\b(?:visa|mastercard|amex|discover|credit|card)\b/i then "credit_card"
      when /\b(?:student|school)\b/i then "student_loan"
      when /\b(?:car|truck|auto|tacoma|vehicle)\b/i then "auto_loan"
      when /\b(?:mortgage|home loan)\b/i then "mortgage"
      when /\b(?:medical|hospital|doctor)\b/i then "medical"
      when /\b(?:personal|signature)\b/i then "personal_loan"
      else "other"
      end
    end

    def builder(command)
      MiaActionDraftBuilder.new(household, user: user, annual_budget_manager: @annual_budget_manager, raw_input: "Review household setup card", command: command).call
    end
  end
end
