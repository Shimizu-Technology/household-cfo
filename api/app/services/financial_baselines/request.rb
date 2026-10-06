module FinancialBaselines
  class Request
    RECURRENCES = %w[unknown recurring one_off seasonal annual].freeze
    ACTUAL_TYPES = %w[purchase fee interest transfer debt_payment cash_withdrawal].freeze

    def initialize(household)
      @household = household
    end

    def call(raw)
      input = raw.to_h.deep_symbolize_keys
      start_on, end_on = date(input.fetch(:window_start_on)), date(input.fetch(:window_end_on))
      raise ArgumentError, "Choose a past baseline window of at most 366 days" unless start_on <= end_on && end_on <= Date.current && (end_on - start_on).to_i < 366
      ids = Array(input.fetch(:revision_ids, [])).map { |id| integer(id) }.uniq.sort
      raise ArgumentError, "Select no more than sixty source revisions" if ids.length > 60
      raise ActiveRecord::RecordNotFound unless FinancialExtractionRevision.where(household: household, id: ids).count == ids.length
      accounts = Array(input.fetch(:tracked_account_ids, [])).map { |id| integer(id) }.uniq.sort
      raise ActiveRecord::RecordNotFound unless SourceTrackedAccount.current_picture.where(household: household, id: accounts).count == accounts.length
      categories = Array(input.fetch(:category_eligibility, [])).map do |raw_category|
        category = raw_category.to_h.deep_symbolize_keys
        record = household.budget_categories.find(category[:budget_category_id]) if category[:budget_category_id]
        recurrence = category.fetch(:recurrence, "unknown").to_s
        raise ArgumentError, "Choose an explicit recurrence assumption" unless RECURRENCES.include?(recurrence)
        raise ArgumentError, "Category eligibility must be true or false" unless category[:eligible].in?([ true, false ])
        { budget_category_id: record&.id, eligible: category[:eligible], recurrence: recurrence, reason: text(category.fetch(:reason)) }
      end.sort_by { |row| row[:budget_category_id].to_i }
      raise ArgumentError, "Review each category only once" unless categories.pluck(:budget_category_id).uniq.length == categories.length
      actuals = Array(input.fetch(:actual_decisions, [])).map do |raw_actual|
        actual = raw_actual.to_h.deep_symbolize_keys
        record = household.household_transactions.find(actual.fetch(:transaction_id))
        type = actual.fetch(:event_type, "purchase").to_s
        disposition = actual.fetch(:disposition, "include").to_s
        raise ArgumentError, "Unsupported actual classification" unless ACTUAL_TYPES.include?(type) && disposition.in?(%w[include exclude match])
        tracked = actual[:tracked_account_id] && SourceTrackedAccount.current_picture.where(household: household).find(actual[:tracked_account_id])
        source = actual[:source_review_version_id] && SourceReviewVersion.where(household: household).find(actual[:source_review_version_id])
        target = actual[:matched_transaction_id] && household.household_transactions.find(actual[:matched_transaction_id])
        overlap = actual.fetch(:overlap_disposition, "new").to_s
        raise ArgumentError, "Choose new, distinct or match overlap treatment" unless overlap.in?(%w[new distinct match])
        raise ArgumentError, "Choose exactly one canonical match target" if disposition == "match" && [ source, target ].compact.length != 1
        { transaction_id: record.id, disposition: disposition, event_type: type, tracked_account_id: tracked&.id, cash: actual[:cash] == true,
          source_review_version_id: source&.id, matched_transaction_id: target&.id, overlap_disposition: overlap, reason: text(actual.fetch(:reason)) }
      end.sort_by { |row| row[:transaction_id] }
      raise ArgumentError, "Review each actual only once" unless actuals.pluck(:transaction_id).uniq.length == actuals.length
      cash_allocations = Array(input.fetch(:cash_allocations, [])).map do |raw_allocation|
        allocation = raw_allocation.to_h.deep_symbolize_keys
        version = SourceReviewVersion.where(household: household).find(allocation.fetch(:source_review_version_id))
        actual = household.household_transactions.find(allocation.fetch(:transaction_id))
        { source_review_version_id: version.id, transaction_id: actual.id, amount_cents: integer(allocation.fetch(:amount_cents)), reason: text(allocation.fetch(:reason)) }
      end.sort_by { |row| [ row[:source_review_version_id], row[:transaction_id] ] }
      raise ArgumentError, "Cash allocations must have distinct row/purchase pairs" unless cash_allocations.map { |row| row.values_at(:source_review_version_id, :transaction_id) }.uniq.length == cash_allocations.length
      cash = input.fetch(:cash_coverage, "unknown").to_s
      raise ArgumentError, "Choose complete, partial, not_used or unknown cash coverage" unless cash.in?(%w[complete partial not_used unknown])
      { window_start_on: start_on.iso8601, window_end_on: end_on.iso8601, revision_ids: ids, tracked_account_ids: accounts,
        category_eligibility: categories, actual_decisions: actuals, cash_allocations: cash_allocations,
        cash_coverage: cash, household_scope_attested: input[:household_scope_attested] == true,
        missing_accounts: Array(input.fetch(:missing_accounts, [])).map { |value| text(value) }.uniq.sort }
    rescue KeyError, TypeError, Date::Error
      raise ArgumentError, "Baseline request is missing or has invalid required fields"
    end

    private

    attr_reader :household

    def date(value)
      raise ArgumentError, "Use an exact YYYY-MM-DD date" unless value.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      Date.iso8601(value.to_s)
    end

    def integer(value)
      raise ArgumentError, "Use a positive exact integer" unless (value.is_a?(Integer) || value.is_a?(String) && value.match?(/\A\d+\z/)) && value.to_i.positive? && value.to_i <= 9_223_372_036_854_775_807
      value.to_i
    end

    def text(value)
      result = value.to_s.unicode_normalize(:nfkc).gsub(/[[:cntrl:]]/, " ").squish
      raise ArgumentError, "A short explanation is required" if result.blank? || result.length > 500
      result
    end
  end
end
