module HouseholdFinance
  class MiaActionDraftPresenter
    def initialize(draft)
      @draft = draft
    end

    def call
      {
        id: draft.id,
        status: draft.status,
        draft_type: draft.draft_type,
        year: draft.year,
        title: draft.title,
        summary: draft.summary,
        rationale: draft.rationale,
        source_prompt: draft.source_prompt,
        created_at: draft.created_at&.iso8601,
        applied_at: draft.applied_at&.iso8601,
        canceled_at: draft.canceled_at&.iso8601,
        impact: draft.metadata.to_h["impact"],
        setup_coverage_after_apply: setup_coverage_after_apply,
        items: action_items
      }
    end

    private

    attr_reader :draft

    def action_items
      draft.mia_action_items.map do |item|
        {
          id: item.id,
          action_type: item.action_type,
          target_record_type: item.target_record_type,
          target_record_id: item.target_record_id,
          label: item.label,
          description: item.description,
          payload: item.payload,
          before_snapshot: item.before_snapshot,
          after_snapshot: item.after_snapshot,
          operation_key: item.operation_key,
          operation_version: item.operation_version,
          review_fields: review_fields(item)
        }
      end
    end

    def review_fields(item)
      return [] if item.operation_key.blank? || item.prepared_operation.blank?

      prepared = item.prepared_operation.to_h
      before = prepared.fetch("before_snapshot", {})
      after = prepared.fetch("predicted_after_snapshot", {})
      case item.operation_key
      when "income.source.create"
        source = after.fetch("source", {})
        [
          { label: "Income source", before: "Does not exist", after: source["label"].to_s },
          { label: "Source type", before: "—", after: source["source_type"].to_s.humanize },
          { label: "Starting amount", before: "$0.00", after: money_from_cents(source["amount_cents"]) },
          { label: "Starts", before: "—", after: month_from_date(source["starts_on"]) }
        ]
      when "income.source.archive"
        income_source_archive_review_fields(before.fetch("source", {}), after.fetch("source", {}))
      when "income.source.update", "income.source.restore"
        income_source_review_fields(before.fetch("source", {}), after.fetch("source", {}))
      when "income.schedule.create", "income.schedule.update", "income.schedule.delete"
        income_schedule_review_fields(item, before, after)
      when "debt.record.create"
        debt_create_review_fields(after.fetch("debt", {}))
      when "debt.record.update", "debt.record.archive", "debt.record.restore"
        debt_review_fields(before.fetch("debt", {}), after.fetch("debt", {}))
      when "debt.tracking_mode.update"
        debt_tracking_review_fields(before, after)
      when "account.record.create"
        account_create_review_fields(after.fetch("account", {}))
      when "account.record.update", "account.record.archive", "account.record.restore", "account.plaid.link", "account.plaid.reconcile", "account.plaid.unlink"
        account_review_fields(before.fetch("account", {}), after.fetch("account", {}))
      when "goal.record.create"
        goal_create_review_fields(after.fetch("goal", {}))
      when "goal.record.update", "goal.record.archive", "goal.record.restore"
        goal_review_fields(before.fetch("goal", {}), after.fetch("goal", {}))
      when "budget.allocation.set"
        before_rows = Array(before["allocations"]).index_by { |row| row["id"] }
        Array(after["allocations"]).map do |row|
          previous = before_rows.fetch(row["id"], {})
          {
            label: "#{month_label(row["month"])} planned amount",
            before: money_from_cents(previous["planned_amount_cents"]),
            after: money_from_cents(row["planned_amount_cents"])
          }
        end
      when "budget.category.create"
        category = after.fetch("category", {})
        normalized_input = prepared.fetch("normalized_input", {})
        [
          { label: "Category", before: "Does not exist", after: category["name"].to_s },
          { label: "Expense stack", before: "—", after: stack_label(category["stack_key"]) },
          { label: "Planned amount", before: "$0.00", after: money_from_cents(normalized_input["monthly_amount_cents"]) }
        ]
      else
        category_before = before.fetch("category", {})
        category_after = after.fetch("category", {})
        fields = []
        fields << { label: "Category name", before: category_before["name"].to_s, after: category_after["name"].to_s } if category_before["name"] != category_after["name"]
        if category_before["stack_key"] != category_after["stack_key"]
          fields << { label: "Expense stack", before: stack_label(category_before["stack_key"]), after: stack_label(category_after["stack_key"]) }
        end
        if category_before["active"] != category_after["active"]
          fields << { label: "Budget status", before: category_before["active"] ? "Active" : "Archived", after: category_after["active"] ? "Active" : "Archived" }
        end
        fields
      end
    end

    def money_from_cents(value)
      ActiveSupport::NumberHelper.number_to_currency(Money.dollars(value.to_i), precision: 2)
    end

    def debt_create_review_fields(debt)
      [
        { label: "Debt", before: "Does not exist", after: debt["label"].to_s },
        { label: "Type", before: "—", after: debt["debt_type"].to_s.humanize },
        { label: "Balance", before: "—", after: debt_money_value(debt, "balance") },
        { label: "Monthly minimum", before: "—", after: debt_money_value(debt, "minimum_payment") },
        { label: "APR", before: "—", after: debt_apr_value(debt["interest_rate_percent"]) }
      ]
    end

    def account_create_review_fields(account)
      [
        { label: "Account", before: "Does not exist", after: account["label"].to_s },
        { label: "Type", before: "—", after: account["account_type"].to_s.humanize },
        { label: "Approved balance", before: "—", after: account_money_value(account) },
        { label: "Balance date", before: "—", after: account["balance_as_of_on"].presence || "Not entered" }
      ]
    end

    def account_review_fields(before, after)
      labels = { "label" => "Account", "account_type" => "Type", "balance_cents" => "Approved balance", "balance_known" => "Approved balance", "balance_as_of_on" => "Balance date", "active" => "Planning status", "plaid_account_id" => "Bank match" }
      handled = []
      labels.filter_map do |key, label|
        next if handled.include?(label)
        next if key == "balance_cents" && before[key] == after[key] && before["balance_known"] == after["balance_known"]
        next if key == "balance_known"
        next if key != "balance_cents" && before[key] == after[key]
        handled << label
        value = lambda do |record|
          case key
          when "balance_cents" then account_money_value(record)
          when "account_type" then record[key].to_s.humanize
          when "active" then record[key] ? "Active" : "Archived"
          when "plaid_account_id" then record[key].present? ? "Matched" : "Not matched"
          else record[key].presence || "Not entered"
          end
        end
        { label: label, before: value.call(before), after: value.call(after) }
      end
    end

    def account_money_value(account)
      return "Not entered" unless account["balance_known"]
      money_from_cents(account["balance_cents"])
    end

    def goal_create_review_fields(goal)
      [
        { label: "Goal", before: "Does not exist", after: goal["label"].to_s },
        { label: "Type", before: "—", after: goal["goal_type"].to_s.humanize },
        { label: "Target", before: "—", after: goal_money_value(goal, "target_amount") },
        { label: "Current progress", before: "—", after: goal_money_value(goal, "current_amount") },
        { label: "Target date", before: "—", after: goal["target_on"].presence || "Not entered" }
      ]
    end

    def goal_review_fields(before, after)
      labels = {
        "label" => "Goal", "goal_type" => "Type", "target_amount_cents" => "Target",
        "target_amount_known" => "Target", "current_amount_cents" => "Current progress",
        "current_amount_known" => "Current progress", "target_on" => "Target date", "active" => "Tracking status"
      }
      handled = []
      labels.filter_map do |key, label|
        next if handled.include?(label)
        known_key = key.sub("_cents", "_known")
        next if key.end_with?("_cents") && before[key] == after[key] && before[known_key] == after[known_key]
        next if key.end_with?("_known")
        next if !key.end_with?("_cents") && before[key] == after[key]
        handled << label
        value = lambda do |record|
          case key
          when "target_amount_cents" then goal_money_value(record, "target_amount")
          when "current_amount_cents" then goal_money_value(record, "current_amount")
          when "goal_type" then record[key].to_s.humanize
          when "active" then record[key] ? "Active" : "Archived"
          else record[key].presence || "Not entered"
          end
        end
        { label: label, before: value.call(before), after: value.call(after) }
      end
    end

    def goal_money_value(goal, prefix)
      return "Not entered" unless goal["#{prefix}_known"]
      money_from_cents(goal["#{prefix}_cents"])
    end

    def debt_review_fields(before, after)
      labels = {
        "label" => "Debt", "debt_type" => "Type", "balance_cents" => "Balance",
        "balance_known" => "Balance", "minimum_payment_cents" => "Monthly minimum",
        "minimum_payment_known" => "Monthly minimum", "interest_rate_percent" => "APR",
        "active" => "Planning status"
      }
      handled = []
      labels.filter_map do |key, label|
        next if handled.include?(label)
        next if key.end_with?("_cents") && before[key] == after[key] && before[key.sub("_cents", "_known")] == after[key.sub("_cents", "_known")]
        next if key.end_with?("_known")
        next if !key.end_with?("_cents") && before[key] == after[key]
        handled << label
        { label: label, before: debt_review_value(key, before), after: debt_review_value(key, after) }
      end
    end

    def debt_tracking_review_fields(before_snapshot, after_snapshot)
      before = before_snapshot.fetch("profile", {})
      after = after_snapshot.fetch("profile", {})
      fields = []
      if before["debt_tracking_mode"] != after["debt_tracking_mode"]
        fields << { label: "Tracking mode", before: before["debt_tracking_mode"].to_s.humanize, after: after["debt_tracking_mode"].to_s.humanize }
        before_portfolio = before_snapshot.fetch("portfolio", {})
        after_portfolio = after_snapshot.fetch("portfolio", {})
        fields << { label: "Planning balance", before: portfolio_debt_money(before_portfolio, "balance"), after: portfolio_debt_money(after_portfolio, "balance") }
        fields << { label: "Planning monthly minimum", before: portfolio_debt_money(before_portfolio, "minimum_payment"), after: portfolio_debt_money(after_portfolio, "minimum_payment") }
        fields << { label: "Active individual records", before: before_portfolio.fetch("active_count", 0).to_s, after: after_portfolio.fetch("active_count", 0).to_s }
      end
      if after["debt_tracking_mode"] == "summary"
        fields << { label: "Summary balance", before: summary_debt_money(before, "balance"), after: summary_debt_money(after, "balance") } if summary_debt_money(before, "balance") != summary_debt_money(after, "balance")
        fields << { label: "Summary monthly minimum", before: summary_debt_money(before, "minimum_payment"), after: summary_debt_money(after, "minimum_payment") } if summary_debt_money(before, "minimum_payment") != summary_debt_money(after, "minimum_payment")
      end
      fields
    end

    def portfolio_debt_money(portfolio, prefix)
      return "Not entered" unless portfolio["#{prefix}_known"]

      money_from_cents(portfolio["#{prefix}_cents"])
    end

    def debt_review_value(key, debt)
      return debt_money_value(debt, "balance") if key == "balance_cents"
      return debt_money_value(debt, "minimum_payment") if key == "minimum_payment_cents"
      return debt_apr_value(debt[key]) if key == "interest_rate_percent"
      return debt[key] ? "Active" : "Archived" if key == "active"
      debt[key].to_s.humanize
    end

    def debt_money_value(debt, prefix)
      return "Not entered" unless debt["#{prefix}_known"]
      money_from_cents(debt["#{prefix}_cents"])
    end

    def summary_debt_money(profile, prefix)
      return "Not entered" unless profile["debt_summary_#{prefix}_known"]
      money_from_cents(profile["debt_summary_#{prefix}_cents"])
    end

    def debt_apr_value(value)
      value.nil? ? "Not entered" : "#{value.to_d.to_s("F").sub(/\.0+\z/, "")}%"
    end

    def income_source_review_fields(before, after)
      labels = {
        "label" => "Income source", "source_type" => "Source type", "amount_cents" => "Base amount",
        "cadence" => "Cadence", "active" => "Status", "starts_on" => "Starts", "ends_on" => "Ends"
      }
      labels.filter_map do |key, label|
        next if key == "active" && before["ends_on"] != after["ends_on"]
        next if before[key] == after[key]
        { label: label, before: income_review_value(key, before[key]), after: income_review_value(key, after[key]) }
      end
    end

    def income_schedule_review_fields(item, before, after)
      entry_id = item.payload.to_h["entry_id"].to_i
      before_entries = Array(before["schedule_entries"])
      after_entries = Array(after["schedule_entries"])
      old_entry = entry_id.positive? ? before_entries.find { |entry| entry["id"].to_i == entry_id } : nil
      new_entry = if item.operation_key == "income.schedule.create"
        input = item.prepared_operation.to_h.fetch("normalized_input", {})
        after_entries.find do |entry|
          entry["entry_type"] == input["entry_type"] && entry["effective_on"] == input["effective_on"] &&
            entry["amount_cents"].to_i == input["amount_cents"].to_i && entry["label"].to_s == input["label"].to_s
        end
      elsif entry_id.positive?
        after_entries.find { |entry| entry["id"].to_i == entry_id }
      end
      keys = { "entry_type" => "Change type", "label" => "Label", "amount_cents" => "Amount", "cadence" => "Cadence", "effective_on" => "Effective month", "retained_after_transition" => "Continues after transition" }
      keys.filter_map do |key, label|
        old_value = old_entry&.[](key)
        new_value = new_entry&.[](key)
        next if old_value == new_value
        { label: label, before: income_review_value(key, old_value, missing: "Does not exist"), after: income_review_value(key, new_value, missing: "Removed") }
      end
    end

    def income_source_archive_review_fields(before, after)
      fields = income_source_review_fields(before, after).reject { |field| field.fetch(:label) == "Ends" }
      if before["ends_on"] != after["ends_on"]
        fields << {
          label: "First $0 month",
          before: before["ends_on"].present? ? "$0 beginning #{month_from_date(before["ends_on"])}" : "Ongoing",
          after: after["ends_on"].present? ? "$0 beginning #{month_from_date(after["ends_on"])}" : "Ongoing"
        }
      end
      fields
    end

    def income_review_value(key, value, missing: "—")
      return missing if value.nil?
      return money_from_cents(value) if key == "amount_cents"
      return month_from_date(value) if key.in?(%w[starts_on ends_on effective_on])
      return value ? "Active" : "Ended" if key == "active"
      return value ? "Yes" : "No" if key == "retained_after_transition"
      value.to_s.humanize
    end

    def month_from_date(value)
      return "—" if value.blank?
      Date.iso8601(value.to_s).strftime("%B %Y")
    rescue Date::Error
      value.to_s
    end

    def month_label(value)
      AnnualBudgetManager::MONTH_NAMES.fetch(value.to_i - 1, "Month #{value}")
    end

    def stack_label(key)
      SnapshotBuilder::STACK_LABELS.fetch(key.to_s, key.to_s.humanize)
    end

    def setup_coverage_after_apply
      return unless draft.draft_type == "household_setup"

      proposed_values = draft.mia_action_items.each_with_object({}) do |item, values|
        next unless item.action_type == "update_setup_value"

        payload = item.payload.to_h
        values[payload["key"]] = payload["value"]
      end
      SetupStatus.new(
        draft.household,
        additional_confirmed_fields: proposed_values.keys,
        proposed_values: proposed_values
      ).as_json
    end
  end
end
