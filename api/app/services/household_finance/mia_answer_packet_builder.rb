# frozen_string_literal: true

module HouseholdFinance
  class MiaAnswerPacketBuilder
    def initialize(kind:, fallback_response:, write_state:, selected_month: nil, annual_plan: nil, spending_report: nil, transaction_draft: nil, conversation_context: nil)
      @kind = kind.to_s
      @fallback_response = fallback_response.to_s
      @write_state = write_state.presence || "no_write"
      @selected_month = selected_month
      @annual_plan = annual_plan
      @spending_report = spending_report
      @transaction_draft = transaction_draft
      @conversation_context = conversation_context
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
        guardrails: guardrails
      }.compact
    end

    private

    attr_reader :kind, :fallback_response, :write_state, :selected_month, :annual_plan, :spending_report, :transaction_draft

    def answer_basis
      case kind
      when "budget_question"
        "active annual plan, confirmed actuals, and pending drafts"
      when "spending_report", "transaction_lookup"
        "confirmed household transactions"
      when "pending_drafts", "transaction_draft"
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
        top_categories: active_rows.first(6).map { |row| { name: row[:name] || row["name"], stack_key: row[:stack_key] || row["stack_key"] } }
      }
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
        top_categories: Array(report[:categories]).first(5).map { |category| category.slice(:name, :planned, :actual, :remaining, :pending) }
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
        end
      }.compact
    end

    def guardrails
      [
        "Use approved structured facts as source of truth.",
        "Separate planned budget, confirmed actuals, and pending drafts.",
        "Do not claim writes happened unless write_state is confirmed_write.",
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
