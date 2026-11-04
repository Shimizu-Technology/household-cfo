module FinancialDocuments
  module SourceReview
    # Whether the statement proved that every line is here. If it did not, the participant is asked, in plain words, whether
    # anything is missing, and only her answer is recorded as the coverage attestation. A statement that reconciles needs no question.
    module CoverageQuestion
      ANSWERS = %w[nothing_missing something_missing].freeze
      module_function

      # "matches" only when the statement's own printed totals agree; a file that prints none is "unchecked", never "matches".
      # Money that does not add up and a line count that differs from the printed one are different problems and are said differently.
      def totals_check(revision)
        report = revision.reconciliation || {}
        accounts = Array(report["accounts"])
        residuals = accounts.flat_map { |account| account.values_at("balance_residual_cents", "debit_residual_cents", "credit_residual_cents") }.compact
        return "mismatch" if report.dig("page_coverage", "all_processed") == false || residuals.any? { |value| value != 0 }
        return "count" if report.dig("row_census", "matches_reported") == false || accounts.any? { |account| account["row_count_matches"] == false }
        accounts.any? && accounts.all? { |account| account["arithmetic_balanced"] == true } ? "matches" : "unchecked"
      end

      def document_covered?(revision)
        pages = revision.reconciliation.fetch("page_coverage", {})
        sheets = revision.reconciliation.fetch("sheet_coverage", {})
        pages["all_processed"] == true || sheets["expected"].to_i.positive? && Array(sheets["processed"]).sort == (0...sheets["expected"].to_i).to_a
      end

      # The question to ask her, or nil when the statement itself shows nothing is missing.
      def text(revision, check: totals_check(revision), deficiencies: [])
        report = revision.reconciliation || {}
        census = report["row_census"] || {}
        case check
        when "count"
          if census["reported"].is_a?(Integer) && census["represented"].is_a?(Integer)
            "Your statement shows #{census['reported']} #{census['reported'] == 1 ? 'line' : 'lines'} and we found #{census['represented']}. Is anything missing?"
          else
            "The number of lines we found doesn’t match your statement. Is anything missing?"
          end
        when "mismatch"
          report.dig("page_coverage", "all_processed") == false ? "We couldn’t read every page of your statement. Is anything missing?" : "The totals on your statement don’t add up with the lines we found. Is anything missing?"
        when "unchecked"
          "This file doesn’t show totals, so we couldn’t check it against your statement. Is anything missing?"
        else
          "We couldn’t confirm we read every page of your statement. Is anything missing?" if deficiencies.include?("document_page_or_sheet_coverage_unverified")
        end
      end

      # What she last said about this statement. It is about the document's rows, so editing a saved line does not undo it.
      def answer(revision)
        approval = SourceRevisionApproval.where(household_id: revision.household_id, financial_extraction_revision: revision).order(version_number: :desc).first
        return unless approval
        approval.coverage_attestation["all_document_rows_accounted"] == true ? "nothing_missing" : "something_missing"
      end
    end
  end
end
