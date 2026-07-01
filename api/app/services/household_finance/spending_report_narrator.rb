module HouseholdFinance
  class SpendingReportNarrator
    def initialize(report)
      @report = report.deep_symbolize_keys
    end

    def call
      totals = report.fetch(:totals)
      categories = report.fetch(:categories)
      top_categories = categories.sort_by { |category| -category.fetch(:actual).to_f }.first(3)
      top_line = top_categories.select { |category| category.fetch(:actual).positive? }.map do |category|
        "#{category.fetch(:name)} #{money(category.fetch(:actual))}"
      end.to_sentence
      top_line = "No confirmed category spending yet" if top_line.blank?

      [
        "For #{report.fetch(:period_label)}, confirmed spending is #{money(totals.fetch(:actual))} against #{money(totals.fetch(:planned))} planned.",
        "Pending drafts waiting for your approval total #{money(totals.fetch(:pending))}; I am not counting those as actuals until you confirm them.",
        "Top actual categories: #{top_line}.",
        closing_line(totals)
      ].join("\n\n")
    end

    private

    attr_reader :report

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
