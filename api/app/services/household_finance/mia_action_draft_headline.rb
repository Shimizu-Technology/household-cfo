module HouseholdFinance
  # Review figures come from prepared changes, never participant-facing prose.
  # Mixed plans and changes without a single meaningful amount have no headline.
  class MiaActionDraftHeadline
    def initialize(draft)
      @draft = draft
      @items = draft.mia_action_items.reject { |item| item.action_type == "confirm_household_setup" }
    end

    def call
      return budget_move if @draft.draft_type == "budget_edit" && @items.length == 2
      return unless @items.one?

      item = @items.first
      input = item.prepared_operation.to_h.fetch("normalized_input", {}).merge(item.payload)
      before = item.prepared_operation.to_h.fetch("before_snapshot", {})
      after = item.prepared_operation.to_h.fetch("predicted_after_snapshot", {})
      case item.action_type
      when "update_allocation"
        values = Array(input["changes"]).pluck("after_cents").uniq
        figure(values.first, "new planned amount") if values.one?
      when "create_category"
        figure(input["monthly_amount_cents"], "planned each month")
      when "create_income_source", "update_income_source", "restore_income_source"
        source = after["source"] || item.after_snapshot
        previous = before["source"] || item.before_snapshot
        return if item.action_type == "update_income_source" && source.values_at("amount_cents", "cadence") == previous.values_at("amount_cents", "cadence")
        income(source)
      when "upsert_income_schedule_entry", "create_income_schedule_entry", "update_income_schedule_entry"
        income(input)
      when "create_debt", "update_debt"
        known_money(before["debt"], after["debt"], [ [ "balance", "debt balance" ], [ "minimum_payment", "monthly minimum" ] ])
      when "create_goal", "update_goal"
        known_money(before["goal"], after["goal"], [ [ "target_amount", "goal target" ], [ "current_amount", "saved toward your goal" ] ])
      when "create_account", "update_account", "reconcile_plaid_account"
        known_money(before["account"], after["account"], [ [ "balance", "account balance" ] ])
      when "update_setup_value"
        figure(input["value_cents"], "new monthly income") if input["key"].in?(%w[primary_income business_income])
      end
    end

    private

    def budget_move
      return unless @items.all? { |item| item.action_type == "update_allocation" }

      rows = @items.map { |item| Array(item.payload["changes"]).sort_by { |row| row["month"].to_i } }
      return if rows.any?(&:empty?) || rows[0].pluck("month") != rows[1].pluck("month")
      deltas = rows.map { |changes| changes.map { |row| row["after_cents"] - row["before_cents"] }.uniq }
      return unless deltas.all?(&:one?) && deltas[0].first == -deltas[1].first && deltas[0].first.nonzero?

      destination = @items[deltas.index { |values| values.first.positive? }]
      label = destination.payload["category_name"] || destination.after_snapshot["category_name"]
      figure(deltas[0].first.abs, "moved to #{label}") if label.present?
    end

    def income(input)
      cents = input["amount_cents"]
      return if cents.nil?
      return figure(cents, "one-time income") if input["entry_type"] == "one_time" || input["cadence"] == "one_time"

      cadence = input["cadence"] || "monthly"
      date = Date.iso8601(input["effective_on"] || input["starts_on"] || "#{@draft.year}-01-01")
      figure(Money.period_cents(cents, cadence, month: date.month), "new monthly income")
    end

    def known_money(before, after, fields)
      return unless after
      previous = before || {}
      changed = fields.find do |key, _label|
        after["#{key}_known"] && (after["#{key}_cents"] != previous["#{key}_cents"] || !previous["#{key}_known"])
      end
      return unless changed
      key, label = changed
      figure(after["#{key}_cents"], label)
    end

    def figure(cents, label)
      return unless cents.is_a?(Integer)
      { amount_cents: cents, label: label }
    end
  end
end
