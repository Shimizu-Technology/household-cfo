module HouseholdFinance
  module MiaActionDraftGoalCommands
    private

    def structured_goal_create_proposal
      label = command[:goal_name].to_s.squish.truncate(120, omission: "…")
      return validation_result("Tell me what this tracked goal should be called. Nothing changed.") if label.blank?
      goal_type = command[:goal_type].to_s
      return validation_result("Choose a supported tracked goal type. Nothing changed.") unless goal_type.in?(::Goal::TRACKED_GOAL_TYPES)
      if household.goals.tracked.active.where(goal_type: goal_type).where("LOWER(label) = ?", label.downcase).exists?
        return validation_result("An active goal already uses that name and type. Tell me which detail to update. Nothing changed.")
      end
      payload = { label: label, goal_type: goal_type, source_type: "mia" }
      add_goal_amount!(payload, :target_amount, :target_amount_cents, :target_amount_known)
      add_goal_amount!(payload, :current_amount, :current_amount_cents, :current_amount_known)
      payload[:target_on] = parsed_goal_date(command[:target_on])
      item = MiaActionDraftBuilder::Item.new(
        action_type: "create_goal", label: "Add #{label}", description: "Add a tracked goal without moving money or changing household cash guidance.",
        target_record_type: "Goal", target_record_id: nil, payload: payload,
        before_snapshot: {}, after_snapshot: payload.merge(active: true, record_kind: "tracked")
      )
      proposal_result(draft_type: "goal_plan", title: "Add tracked goal", summary: "I prepared #{label} for your review.", rationale: "The goal records your approved target and progress only after you apply this card. It does not move money or change runway or safe-to-spend.", items: [ item ], metadata: { source: "mia_chat", parser: "model_intent" })
    rescue ArgumentError => e
      validation_result("#{e.message}. Nothing changed.")
    end

    def structured_goal_update_proposal
      goal = structured_goal(active: true)
      return validation_result("I could not safely match that active tracked goal. Name it exactly or choose it by id. Nothing changed.") unless goal
      payload = { goal_id: goal.id }
      payload[:label] = command[:new_name].to_s.squish.truncate(120, omission: "…") if command[:new_name].present?
      payload[:goal_type] = command[:goal_type] if command[:goal_type].to_s.in?(::Goal::TRACKED_GOAL_TYPES)
      add_goal_amount!(payload, :target_amount, :target_amount_cents, :target_amount_known) if command.key?(:target_amount) && command[:target_amount].present?
      add_goal_amount!(payload, :current_amount, :current_amount_cents, :current_amount_known) if command.key?(:current_amount) && command[:current_amount].present?
      payload[:target_on] = parsed_goal_date(command[:target_on]) if command[:target_on].present?
      return validation_result("Tell me which goal detail to update. Nothing changed.") if payload.one?
      before = goal_action_snapshot(goal)
      item = MiaActionDraftBuilder::Item.new(
        action_type: "update_goal", label: "Update #{goal.label}", description: "Review each changed goal field before applying.",
        target_record_type: "Goal", target_record_id: goal.id, payload: payload,
        before_snapshot: before, after_snapshot: before.merge(payload.except(:goal_id))
      )
      proposal_result(draft_type: "goal_plan", title: "Update tracked goal", summary: "I prepared an update to #{goal.label} for your review.", rationale: "This changes the tracked goal only. Accounts, debt, budget, income, runway, and safe-to-spend stay unchanged.", items: [ item ], metadata: { source: "mia_chat", parser: "model_intent" })
    rescue ArgumentError => e
      validation_result("#{e.message}. Nothing changed.")
    end

    def structured_goal_status_proposal(archive:)
      goal = structured_goal(active: archive)
      return validation_result("I could not safely match that #{archive ? 'active' : 'archived'} tracked goal. Name it exactly or choose it by id. Nothing changed.") unless goal
      action = archive ? "archive_goal" : "restore_goal"
      item = MiaActionDraftBuilder::Item.new(
        action_type: action, label: "#{archive ? 'Archive' : 'Restore'} #{goal.label}",
        description: archive ? "Remove this goal from active goal totals while preserving its history." : "Return this goal to active tracking without creating a duplicate.",
        target_record_type: "Goal", target_record_id: goal.id, payload: { goal_id: goal.id },
        before_snapshot: goal_action_snapshot(goal), after_snapshot: goal_action_snapshot(goal).merge(active: !archive)
      )
      proposal_result(draft_type: "goal_plan", title: "#{archive ? 'Archive' : 'Restore'} tracked goal", summary: "I prepared #{goal.label} for your review.", rationale: "No money moves and all household financial facts remain unchanged.", items: [ item ], metadata: { source: "mia_chat", parser: "model_intent" })
    end

    def structured_goal(active:)
      scope = household.goals.tracked.where(active: active)
      return scope.find_by(id: command[:goal_id].to_i) if command[:goal_id].to_i.positive?
      name = command[:goal_name].to_s.squish
      return if name.blank?
      matches = scope.where("LOWER(label) = ?", name.downcase).to_a
      matches.one? ? matches.first : nil
    end

    def add_goal_amount!(payload, command_key, cents_key, known_key)
      value = command[command_key]
      if value.nil? || value.to_s.strip.blank? || value.to_s.casecmp("unknown").zero?
        payload[cents_key] = 0
        payload[known_key] = false
      else
        payload[cents_key] = Money.cents!(value, message: command_key.to_s.humanize + " must be a number")
        payload[known_key] = true
      end
    end

    def parsed_goal_date(value)
      return nil if value.blank? || value.to_s.downcase.in?(%w[unknown none])
      Date.iso8601(value.to_s).iso8601
    rescue Date::Error
      raise ArgumentError, "Target date must be valid"
    end

    def goal_action_snapshot(goal)
      {
        id: goal.id, label: goal.label, goal_type: goal.goal_type,
        target_amount_cents: goal.target_amount_cents, target_amount_known: goal.target_amount_known?,
        current_amount_cents: goal.current_amount_cents, current_amount_known: goal.current_amount_known?,
        target_on: goal.target_on&.iso8601, priority: goal.priority,
        active: goal.active?, archived_at: goal.archived_at&.iso8601,
        source_type: goal.source_type, source_metadata: goal.source_metadata, record_kind: goal.record_kind
      }
    end
  end
end
