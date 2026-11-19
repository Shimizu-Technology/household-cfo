module Scorecard
  class Ratchet
    # Compare each error separately: one better month must not conceal another
    # worse month; category, income, receipt and analyzer regressions count too.
    def self.regressions(actual, baseline, path = [])
      raise ArgumentError, "Baseline shape changed" unless actual.class == baseline.class || [ true, false ].include?(actual) && [ true, false ].include?(baseline)
      case baseline
      when Hash
        if %w[decisions_by_kind corrections_by_field questions_by_kind].include?(path.last)
          return (actual.keys | baseline.keys).flat_map do |key|
            regressions(actual.fetch(key, 0), baseline.fetch(key, 0), path + [ key ])
          end
        end
        raise ArgumentError, "Baseline keys changed" unless actual.keys.sort == baseline.keys.sort
        baseline.flat_map { |key, value| regressions(actual.fetch(key), value, path + [ key ]) }
      when Array
        raise ArgumentError, "Baseline array changed" unless actual.length == baseline.length
        baseline.each_with_index.flat_map { |value, index| regressions(actual[index], value, path + [ index.to_s ]) }
      when Numeric
        key = path.last
        if %w[expected_cents expected_count expected_rows document_count schema_version].include?(key)
          raise ArgumentError, "Baseline scope changed" unless actual == baseline
        end
        worse = if %w[error_cents error_count].include?(key)
          actual.abs > baseline.abs
        elsif %w[decisions_by_kind corrections_by_field questions_by_kind].include?(path[-2]) || %w[manual_correction manual_exclusion unmapped_spending_cents unmapped_spending_count double_counts transfer_leakage_cents transfer_leakage_spending_cents transfer_leakage_income_cents decisions receipt_new_money_absolute_error_cents receipt_category_allocation_error_cents category_allocation_error_cents receipt_extraction_absolute_error_cents missing_rows unrecognized_rows].include?(key)
          actual > baseline
        elsif %w[receipt_matches accepted_as_proposed].include?(key)
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
