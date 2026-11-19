module Scorecard
  class Ratchet
    # Compare each error separately: one better month must not conceal another
    # worse month; category, income, receipt and analyzer regressions count too.
    def self.regressions(actual, baseline, path = [])
      raise ArgumentError, "Baseline shape changed" unless actual.class == baseline.class || [ true, false ].include?(actual) && [ true, false ].include?(baseline)
      case baseline
      when Hash
        raise ArgumentError, "Baseline keys changed" unless path.last == "decisions_by_kind" || actual.keys.sort == baseline.keys.sort
        baseline.flat_map { |key, value| key == "decisions_by_kind" ? [] : regressions(actual.fetch(key), value, path + [ key ]) }
      when Array
        raise ArgumentError, "Baseline array changed" unless actual.length == baseline.length
        baseline.each_with_index.flat_map { |value, index| regressions(actual[index], value, path + [ index.to_s ]) }
      when Numeric
        key = path.last
        if key.in?(%w[expected_cents expected_count expected_rows document_count])
          raise ArgumentError, "Baseline scope changed" unless actual == baseline
        end
        worse = if key.in?(%w[error_cents error_count])
          actual.abs > baseline.abs
        elsif key.in?(%w[double_counts transfer_leakage_cents transfer_leakage_spending_cents transfer_leakage_income_cents decisions receipt_new_money_absolute_error_cents receipt_category_allocation_error_cents category_allocation_error_cents receipt_extraction_absolute_error_cents missing_rows unrecognized_rows])
          actual > baseline
        elsif key == "receipt_matches"
          actual < baseline
        else
          false
        end
        worse ? [ path.join(".") ] : []
      when TrueClass, FalseClass
        baseline && !actual ? [ path.join(".") ] : []
      else
        actual == baseline ? [] : [ path.join(".") ]
      end
    end
  end
end
