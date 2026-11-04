# frozen_string_literal: true

module HouseholdFinance
  class MiaAnswerPacketBuilder
    def initialize(kind:, fallback_response:, write_state:, selected_month: nil, annual_plan: nil, spending_report: nil, transaction_draft: nil, conversation_context: nil, mia_action_result: nil, month_answer: nil, participant_message: nil, reflection: false)
      @month_answer = month_answer
      @participant_message = participant_message.to_s
      @reflection = reflection
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
        coaching_priority: coaching_priority,
        coaching_provenance: coaching_provenance,
        write_state: write_state,
        fallback_response: fallback_response,
        selected_year: annual_plan_year,
        selected_month: selected_month,
        annual_plan_summary: annual_plan_summary,
        spending_report_summary: spending_report_summary,
        transaction_draft: transaction_draft_packet,
        budget_action: budget_action_packet,
        personalization_memory: personalization_memory,
        conversation_state: conversation_state,
        guardrails: guardrails
      }.compact
    end

    private

    attr_reader :kind, :fallback_response, :write_state, :selected_month, :annual_plan, :spending_report, :transaction_draft, :conversation_context, :mia_action_result

    def answer_basis
      return "participant-reported experience; coaching guidance is not a verified financial outcome" if @reflection
      return "participant-stated essential need; general coach guidance; no financial achievement established" if coaching_priority.in?(%w[hardship essential_skip])

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

    def coaching_provenance
      return unless @reflection || coaching_priority.in?(%w[hardship essential_skip])

      { participant_report: @participant_message,
        achievement_basis: "participant report only",
        cause: "unknown unless explicitly stated by participant",
        financial_effect: "not established by this report",
        guidance_basis: "assigned coach method; suggestions are not claims about what the participant did" }
    end

    def annual_plan_year
      return unless annual_plan

      annual_plan[:year] || annual_plan["year"]
    end

    def coaching_priority
      MiaCoachAnswerer.routing_priority(@participant_message).to_s if @participant_message.present?
    end

    def annual_plan_summary
      return { month_answer: month_answer } if @month_answer && !annual_plan
      return unless annual_plan

      rows = Array(annual_plan[:rows] || annual_plan["rows"])
      active_rows = rows.select { |row| active_row?(row) }
      pending = Array(annual_plan[:pending_transaction_drafts] || annual_plan["pending_transaction_drafts"])
      pending_meta = (annual_plan[:pending_transaction_drafts_meta] || annual_plan["pending_transaction_drafts_meta"] || {}).symbolize_keys
      {
        year: annual_plan_year,
        category_period: category_period,
        active_category_count: active_rows.length,
        pending_draft_count: pending_meta[:truncated] ? nil : pending.length,
        month_answer: month_answer,
        top_categories: summarized_categories(active_rows)
      }
    end

    def month_answer
      facts = @month_answer
      return unless facts

      facts.merge(coaching_figures: facts.filter_map do |key, value|
        [ key, (BigDecimal(value.to_s) / 100).round * 100 ] if key.to_s.end_with?("_cents") && !value.nil?
      end.to_h)
    end

    def category_period
      return unless selected_month.to_i.between?(1, 12)

      date = Date.new(annual_plan_year.to_i, selected_month.to_i, 1)
      { unit: "month", year: date.year, month: date.month, label: date.strftime("%B %Y") }
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
        category_creation: transaction_draft.transaction_draft_splits.any? { |split| split.budget_category_id.nil? && split.category_name.present? } ? "Named new categories are created only when this purchase review is confirmed." : nil,
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

    def personalization_memory
      context = conversation_context.respond_to?(:deep_symbolize_keys) ? conversation_context.deep_symbolize_keys : {}
      context[:personalization_memory]
    end

    def guardrails
      [
        "Use approved structured facts as source of truth.",
        "Category figures belong to annual_plan_summary.category_period, not the whole plan year. Preserve that period whenever quoting them.",
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
