module HouseholdFinance
  module MiaActionDraftAssetCommands
    private

    def structured_account_create_proposal
      label = command[:account_name].to_s.squish.truncate(120, omission: "…")
      return validation_result("Tell me what this account should be called. Nothing changed.") if label.blank?
      account_type = command[:account_type].to_s
      return validation_result("Choose a supported account type. Nothing changed.") unless account_type.in?(::Account::ACCOUNT_TYPES)
      if household.accounts.active.where(account_type: account_type).where("LOWER(label) = ?", label.downcase).exists?
        return validation_result("An active account already uses that name and type. Tell me which detail to update. Nothing changed.")
      end
      payload = { label: label, account_type: account_type, source_type: "mia" }
      add_account_balance!(payload, command[:amount])
      if payload[:balance_known] && command[:balance_as_of_on].present?
        payload[:balance_as_of_on] = parsed_account_date(command[:balance_as_of_on])
      end
      item = MiaActionDraftBuilder::Item.new(
        action_type: "create_account", label: "Add #{label}", description: "Add an approved household account. A blank balance stays unknown instead of becoming $0.",
        target_record_type: "Account", target_record_id: nil, payload: payload,
        before_snapshot: {}, after_snapshot: payload.merge(active: true)
      )
      proposal_result(draft_type: "asset_plan", title: "Add account", summary: "I prepared #{label} for your review.", rationale: "The account affects household guidance only after you apply this card. No bank transaction occurs.", items: [ item ], metadata: { source: "mia_chat", parser: "model_intent" })
    rescue ArgumentError => e
      validation_result("#{e.message}. Nothing changed.")
    end

    def structured_account_update_proposal
      account = structured_account(active: true)
      return validation_result("I could not safely match that active account. Name it exactly or choose it by id. Nothing changed.") unless account
      payload = { account_id: account.id }
      payload[:label] = command[:new_name].to_s.squish.truncate(120, omission: "…") if command[:new_name].present?
      payload[:account_type] = command[:account_type] if command[:account_type].to_s.in?(::Account::ACCOUNT_TYPES)
      if command.key?(:amount) && command[:amount].present?
        add_account_balance!(payload, command[:amount])
        if payload[:balance_known]
          payload[:balance_as_of_on] = parsed_account_date(command[:balance_as_of_on]) if command[:balance_as_of_on].present?
        else
          payload[:balance_as_of_on] = nil
        end
      elsif command[:balance_as_of_on].present?
        return validation_result("Enter the account balance before adding a balance date. Nothing changed.") unless account.balance_known?
        payload[:balance_as_of_on] = parsed_account_date(command[:balance_as_of_on])
      end
      return validation_result("Tell me which account detail to update. Nothing changed.") if payload.one?
      before = account_action_snapshot(account)
      item = MiaActionDraftBuilder::Item.new(
        action_type: "update_account", label: "Update #{account.label}", description: "Review each changed account field before applying.",
        target_record_type: "Account", target_record_id: account.id, payload: payload,
        before_snapshot: before, after_snapshot: before.merge(payload.except(:account_id))
      )
      proposal_result(draft_type: "asset_plan", title: "Update account", summary: "I prepared an update to #{account.label} for your review.", rationale: "The approved balance stays unchanged until you apply this card.", items: [ item ], metadata: { source: "mia_chat", parser: "model_intent" })
    rescue ArgumentError => e
      validation_result("#{e.message}. Nothing changed.")
    end

    def structured_account_status_proposal(archive:)
      account = structured_account(active: archive)
      return validation_result("I could not safely match that #{archive ? 'active' : 'archived'} account. Name it exactly or choose it by id. Nothing changed.") unless account
      action = archive ? "archive_account" : "restore_account"
      item = MiaActionDraftBuilder::Item.new(
        action_type: action, label: "#{archive ? 'Archive' : 'Restore'} #{account.label}",
        description: archive ? "Remove this account from planning totals while preserving its history and bank match." : "Return this account to planning without creating a duplicate.",
        target_record_type: "Account", target_record_id: account.id, payload: { account_id: account.id },
        before_snapshot: account_action_snapshot(account), after_snapshot: account_action_snapshot(account).merge(active: !archive)
      )
      proposal_result(draft_type: "asset_plan", title: "#{archive ? 'Archive' : 'Restore'} account", summary: "I prepared #{account.label} for your review.", rationale: "No money moves and history remains preserved.", items: [ item ], metadata: { source: "mia_chat", parser: "model_intent" })
    end

    def structured_account_link_proposal
      account = structured_account(active: true)
      observation = ::PlaidAccount.joins(:plaid_item).where(plaid_items: { household_id: household.id, financial_generation: household.financial_generation }).find_by(id: command[:plaid_account_id].to_i)
      eligibility = observation && PlaidIntegration::AccountEligibility.new(observation)
      return validation_result("Choose an active saved account and eligible bank observation. Nothing changed.") unless account && eligibility&.active_observation? && eligibility.allowed_account_types.include?(account.account_type)
      return validation_result("That household account is already matched to a bank observation. Unmatch it before choosing another one. Nothing changed.") if account.plaid_account_id
      return validation_result("That bank observation is already matched to another household account. Nothing changed.") if observation.account
      item = MiaActionDraftBuilder::Item.new(
        action_type: "link_plaid_account", label: "Match #{account.label} to #{observation.name}", description: "Save the bank observation as a match without changing the approved balance.",
        target_record_type: "Account", target_record_id: account.id, payload: { account_id: account.id, plaid_account_id: observation.id },
        before_snapshot: account_action_snapshot(account), after_snapshot: account_action_snapshot(account).merge(plaid_account_id: observation.id)
      )
      proposal_result(draft_type: "asset_plan", title: "Match bank observation", summary: "I prepared a bank match for #{account.label}.", rationale: "The current bank value stays observational until you separately accept it.", items: [ item ], metadata: { source: "mia_chat", parser: "model_intent" })
    end

    def structured_account_reconcile_proposal
      account = structured_account(active: true)
      decision = command[:reconcile_decision].to_s
      return validation_result("Choose an account that is already matched to a bank observation. Nothing changed.") unless account&.plaid_account
      return validation_result("Choose whether to accept the observed balance or keep the saved balance. Nothing changed.") unless decision.in?(%w[accept_observed keep_saved])
      eligibility = PlaidIntegration::AccountEligibility.new(account.plaid_account)
      return validation_result("Sync or reconnect that bank account before reconciling it. Nothing changed.") unless eligibility.active_observation? && account.plaid_account.plaid_item.last_synced_at.present?
      if decision == "accept_observed" && !eligibility.current_balance_available?
        return validation_result("The current bank balance is unavailable. Keep the saved balance or sync again. Nothing changed.")
      end
      item = MiaActionDraftBuilder::Item.new(
        action_type: "reconcile_plaid_account", label: "Review #{account.label} bank balance", description: decision == "accept_observed" ? "Accept the latest observed balance as the approved household balance." : "Keep the approved balance and mark the observation reviewed.",
        target_record_type: "Account", target_record_id: account.id, payload: { account_id: account.id, decision: decision },
        before_snapshot: account_action_snapshot(account), after_snapshot: account_action_snapshot(account).merge(balance_cents: decision == "accept_observed" ? account.plaid_account.current_balance_cents : account.balance_cents)
      )
      proposal_result(draft_type: "asset_plan", title: "Reconcile bank balance", summary: "I prepared the #{account.label} observation for review.", rationale: "You choose whether the bank observation replaces the saved balance.", items: [ item ], metadata: { source: "mia_chat", parser: "model_intent" })
    end

    def structured_account_unlink_proposal
      account = structured_account(active: true)
      return validation_result("Choose an account that is already matched to a bank observation. Nothing changed.") unless account&.plaid_account
      item = MiaActionDraftBuilder::Item.new(
        action_type: "unlink_plaid_account", label: "Unmatch #{account.label}", description: "Remove the bank match while preserving the approved account and balance.",
        target_record_type: "Account", target_record_id: account.id, payload: { account_id: account.id }, before_snapshot: account_action_snapshot(account), after_snapshot: account_action_snapshot(account).merge(plaid_account_id: nil)
      )
      proposal_result(draft_type: "asset_plan", title: "Remove bank match", summary: "I prepared removing the bank match from #{account.label}.", rationale: "The saved account and approved balance remain intact.", items: [ item ], metadata: { source: "mia_chat", parser: "model_intent" })
    end

    def structured_account(active:)
      scope = household.accounts.where(active: active)
      return scope.find_by(id: command[:account_id].to_i) if command[:account_id].to_i.positive?
      name = command[:account_name].to_s.squish
      return if name.blank?
      matches = scope.where("LOWER(label) = ?", name.downcase).to_a
      matches.one? ? matches.first : nil
    end

    def add_account_balance!(payload, value)
      if value.nil? || value.to_s.strip.blank? || value.to_s.casecmp("unknown").zero?
        payload[:balance_cents] = 0
        payload[:balance_known] = false
        return
      end
      text = value.to_s.strip
      raise ArgumentError, "Balance must be a number" unless text.match?(/\A-?\d{1,9}(?:\.\d{1,2})?\z/)
      cents = Money.cents(text.delete_prefix("-")) * (text.start_with?("-") ? -1 : 1)
      type = (payload[:account_type] || structured_account(active: true)&.account_type).to_s
      raise ArgumentError, "Only checking and savings can have a negative balance" if cents.negative? && !type.in?(::Account::SIGNED_BALANCE_TYPES)
      payload[:balance_cents] = cents
      payload[:balance_known] = true
    end

    def parsed_account_date(value)
      return Date.current if value.blank?
      Date.iso8601(value.to_s)
    rescue Date::Error
      raise ArgumentError, "Balance date must be valid"
    end

    def account_action_snapshot(account)
      {
        id: account.id, label: account.label, account_type: account.account_type,
        balance_cents: account.balance_cents, balance_known: account.balance_known?, balance_as_of_on: account.balance_as_of_on&.iso8601,
        active: account.active?, archived_at: account.archived_at&.iso8601, source_type: account.source_type,
        plaid_account_id: account.plaid_account_id
      }
    end
  end
end
