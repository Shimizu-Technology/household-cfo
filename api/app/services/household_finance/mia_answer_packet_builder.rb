# frozen_string_literal: true

module HouseholdFinance
  class MiaAnswerPacketBuilder
    def initialize(kind:, fallback_response:, write_state:, selected_month: nil, annual_plan: nil, spending_report: nil, transaction_draft: nil, conversation_context: nil, mia_action_result: nil)
      @kind = kind.to_s
      @fallback_response = fallback_response.to_s
      @write_state = write_state.presence || "no_write"
      @selected_month = selected_month
      @annual_plan = annual_plan
      @spending_report = spending_report
      @transaction_draft = transaction_draft
      @conversation_context = conversation_context
      @mia_action_result = mia_action_result
    end

    def call
      {
        kind: kind,
        basis: answer_basis,
        write_state: write_state,
        fallback_response: fallback_response,
        selected_year: annual_plan_year,
        selected_month: selected_month,
        annual_plan_summary: annual_plan_summary,
        spending_report_summary: spending_report_summary,
        transaction_draft: transaction_draft_packet,
        budget_action: budget_action_packet,
        conversation_state: conversation_state,
        guardrails: guardrails
      }.compact
    end

    private

    attr_reader :kind, :fallback_response, :write_state, :selected_month, :annual_plan, :spending_report, :transaction_draft, :conversation_context, :mia_action_result

    def answer_basis
      case kind
      when "budget_question"
        "active annual plan, confirmed actuals, and pending drafts"
      when "spending_report", "transaction_lookup"
        "confirmed household transactions"
      when "pending_drafts", "transaction_draft", "transaction_draft_update"
        "pending transaction drafts awaiting Household CFO review"
      else
        "approved household profile, active annual plan, confirmed actuals, and pending drafts"
      end
    end

    def annual_plan_year
      return unless annual_plan

      annual_plan[:year] || annual_plan["year"]
    end

    def annual_plan_summary
      return unless annual_plan

      rows = Array(annual_plan[:rows] || annual_plan["rows"])
      active_rows = rows.select { |row| active_row?(row) }
      pending = Array(annual_plan[:pending_transaction_drafts] || annual_plan["pending_transaction_drafts"])
      {
        year: annual_plan_year,
        active_category_count: active_rows.length,
        pending_draft_count: pending.length,
        top_categories: summarized_categories(active_rows)
      }
    end

    def summarized_categories(active_rows)
      month_index = selected_month.to_i.positive? ? selected_month.to_i - 1 : nil
      rows = month_index ? active_rows.sort_by { |row| -month_amount(row, month_index, :planned) } : active_rows
      rows.first(8).map do |row|
        payload = { name: row[:name] || row["name"], stack_key: row[:stack_key] || row["stack_key"] }
        if month_index
          payload.merge(
            planned: month_amount(row, month_index, :planned),
            actual: month_amount(row, month_index, :actual),
            remaining: month_amount(row, month_index, :remaining)
          )
        else
          payload
        end
      end
    end

    def month_amount(row, month_index, key)
      month = Array(row[:months] || row["months"])[month_index]
      return 0 unless month

      (month[key] || month[key.to_s] || 0).to_f
    end

    def active_row?(row)
      row[:active] != false && row["active"] != false
    end

    def spending_report_summary
      return unless spending_report

      report = spending_report.respond_to?(:deep_symbolize_keys) ? spending_report.deep_symbolize_keys : {}
      {
        period_label: report[:period_label],
        start_on: report[:start_on],
        end_on: report[:end_on],
        totals: report[:totals],
        pending_draft_count: Array(report[:pending_drafts]).length,
        confirmed_transaction_count: Array(report[:transactions]).length,
        top_categories: Array(report[:categories]).first(5).map { |category| category.slice(:name, :planned, :actual, :remaining, :pending) },
        top_transactions: Array(report[:transactions]).first(5).map { |transaction| transaction.slice(:occurred_on, :merchant, :amount, :categories) }
      }.compact
    end

    def transaction_draft_packet
      return unless transaction_draft

      {
        merchant: transaction_draft.merchant,
        occurred_on: transaction_draft.occurred_on&.iso8601,
        amount: money(transaction_draft.total_amount_cents),
        category: transaction_draft.budget_category&.name,
        status: transaction_draft.status,
        source_type: transaction_draft.source_type,
        splits: transaction_draft.transaction_draft_splits.ordered.includes(:budget_category).map do |split|
          {
            category: split.budget_category&.name || split.category_name,
            amount: money(split.amount_cents),
            notes: split.notes
          }
        end,
        budget_impacts_if_approved: transaction_draft_budget_impacts
      }.compact
    end

    def transaction_draft_budget_impacts
      return unless annual_plan

      HouseholdFinance::TransactionDraftBudgetImpact.new(annual_plan: annual_plan, draft: transaction_draft).call.map do |impact|
        impact.dup.tap do |payload|
          %i[draft_amount_cents planned_cents actual_cents other_pending_cents projected_if_approved_cents remaining_if_approved_cents].each do |key|
            payload[key.to_s.delete_suffix("_cents").to_sym] = money(payload.delete(key)) if payload.key?(key)
          end
        end
      end
    end

    def budget_action_packet
      return unless mia_action_result

      if (proposal = mia_action_result.proposal)
        return {
          status: "proposed",
          title: proposal.title,
          summary: proposal.summary,
          rationale: proposal.rationale,
          items: proposal.items.map do |item|
            {
              action_type: item.action_type,
              label: item.label,
              description: item.description,
              before: item.before_snapshot,
              after: item.after_snapshot
            }
          end
        }
      end

      draft = mia_action_result.existing_draft
      return unless draft

      {
        id: draft.id,
        status: draft.status,
        title: draft.title,
        summary: draft.summary
      }
    end

    def conversation_state
      context = conversation_context.respond_to?(:deep_symbolize_keys) ? conversation_context.deep_symbolize_keys : {}
      {
        active_thread: context[:active_topic],
        open_threads: Array(context[:open_topics]).first(4),
        older_summary: context[:rolling_summary]
      }.compact
    end

    def guardrails
      [
        "Use approved structured facts as source of truth.",
        "Separate planned budget, confirmed actuals, and pending drafts.",
        "Do not claim official budget or actual writes happened unless write_state is confirmed_write.",
        "When write_state is draft_updated, the pending review fields changed but actuals did not.",
        "End with one concrete Household CFO next move."
      ]
    end

    def money(cents)
      ActionController::Base.helpers.number_to_currency(
        HouseholdFinance::Money.dollars(cents),
        precision: cents.to_i % 100 == 0 ? 0 : 2
      )
    end
  end
end
