module HouseholdFinance
  class SpendingReportNarrator
    BUDGET_STATUS_TERMS = /\b(staying within|within (?:my|our|the)?\s*budget|under budget|over budget|on track|off track|am i okay|are we okay)\b/i

    def initialize(report, prompt: nil)
      @report = report.deep_symbolize_keys
      @prompt = prompt.to_s
    end

    def call
      totals = report.fetch(:totals)
      categories = report.fetch(:categories)
      top_categories = categories.sort_by { |category| -category.fetch(:actual).to_f }.first(3)
      top_line = top_categories.select { |category| category.fetch(:actual).positive? }.map do |category|
        "#{category.fetch(:name)} #{money(category.fetch(:actual))}"
      end.to_sentence
      top_line = "No confirmed category spending yet" if top_line.blank?

      return budget_status_answer(totals, top_line) if budget_status_question?

      [
        "For #{report.fetch(:period_label)}, based on confirmed transactions, confirmed spending is #{money(totals.fetch(:actual))} against #{money(totals.fetch(:planned))} planned.",
        "Pending drafts waiting for your approval total #{money(totals.fetch(:pending))}; I am not counting those as actuals until you confirm them.",
        "Top actual categories: #{top_line}.",
        closing_line(totals)
      ].join("\n\n")
    end

    private

    attr_reader :report, :prompt

    def budget_status_question?
      prompt.match?(BUDGET_STATUS_TERMS)
    end

    def budget_status_answer(totals, top_line)
      planned = totals.fetch(:planned).to_f
      actual = totals.fetch(:actual).to_f
      pending = totals.fetch(:pending).to_f
      remaining = totals.fetch(:remaining).to_f
      projected_remaining = planned - actual - pending
      status_line = if remaining.negative?
        "No — based on confirmed transactions for #{report.fetch(:period_label)}, you are #{money(remaining.abs)} over the confirmed budget: #{money(actual)} actual against #{money(planned)} planned."
      elsif pending.positive? && projected_remaining.negative?
        "Almost — based on confirmed transactions for #{report.fetch(:period_label)}, spending is within budget, but pending drafts would put you #{money(projected_remaining.abs)} over if you approve all of them."
      else
        "Yes — based on confirmed transactions for #{report.fetch(:period_label)}, you are within budget: #{money(actual)} confirmed against #{money(planned)} planned."
      end

      pending_line = pending.positive? ? "You also have #{money(pending)} waiting for approval, and I am not counting that as actual until you confirm it." : "No pending drafts are waiting on this period."
      remaining_line = remaining.negative? ? "Confirmed actuals are over by #{money(remaining.abs)}. Top actual categories: #{top_line}." : "You have #{money(remaining)} left on confirmed actuals. Top actual categories: #{top_line}."
      next_move = remaining.negative? ? "Your next CFO move is to name what was one-time versus a repeat pattern before cutting essentials." : "Keep logging before the small purchases turn into a mystery, then make the next approval on purpose."

      [ status_line, remaining_line, pending_line, next_move ].join("\n\n")
    end

    def closing_line(totals)
      remaining = totals.fetch(:remaining).to_f
      return "You are #{money(remaining)} under the planned amount for this period so far." if remaining.positive?
      return "You are exactly at the planned amount for this period." if remaining.zero?

      "You are #{money(remaining.abs)} over the planned amount for this period. Review what was structural versus one-off before cutting essentials."
    end

    def money(value)
      ActiveSupport::NumberHelper.number_to_currency(value, precision: 0)
    end
  end
end
