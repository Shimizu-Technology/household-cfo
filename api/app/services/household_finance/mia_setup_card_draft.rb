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
        draft_type: "household_setup", title: MiaSetupCardTurn::TITLE, summary: MiaSetupCardTurn::TITLE, rationale: "", source_prompt: source_prompt,
        items: items, metadata: { source: "mia_chat", parser: "setup_card", setup_card: card.to_h.merge("blocked" => blocked) }.merge(card.spending_preferences.any? ? { spending_preferences: card.spending_preferences } : {}))
    end

    attr_reader :household, :user, :card

    def setup_items(blocked)
      updates = card.setup_updates
      return [] if updates.empty?
      result = builder(type: "update_household_setup", setup_updates: updates, spending_preferences: card.spending_preferences.presence)
      return result.proposal.items if result&.proposal

      workable = updates.select do |field, value|
        single = builder(type: "update_household_setup", setup_updates: { field => value })
        next true if single&.proposal
        blocked[field.to_s] = single&.response.to_s unless single&.response.to_s.start_with?("Those household values")
        false
      end
      return [] if workable.empty?
      builder(type: "update_household_setup", setup_updates: workable, spending_preferences: card.spending_preferences.presence)&.proposal&.items.to_a
    end

    def debt_items(blocked)
      state = card.debt_state
      return [] if state.empty? || !card.debts_changed?
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

    def named_debt_commands(state)
      parts = Array(state["parts"])
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
