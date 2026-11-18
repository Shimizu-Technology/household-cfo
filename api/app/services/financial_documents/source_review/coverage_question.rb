module FinancialDocuments
  module SourceReview
    # Whether the statement proved that every line is here. If it did not, the participant is asked, in plain words, whether
    # anything is missing, and only her answer is recorded as the coverage attestation. A statement that reconciles needs no question.
    module CoverageQuestion
      ANSWERS = %w[nothing_missing something_missing].freeze
      # Lines unresolved only because the reader couldn't say what kind of line they are. A line whose amount, date
      # or source is in doubt never helps prove the totals close.
      CLASSIFICATION_ONLY = %w[event_classification_unknown row_kind_missing_or_invalid merchant_missing].freeze
      module_function

      # "matches" only when the statement's own printed totals agree; a file that prints none is "unchecked", never "matches".
      # Money that does not add up and a line count that differs from the printed one are different problems and are said differently.
      def totals_check(revision)
        report = revision.reconciliation || {}
        accounts = Array(report["accounts"])
        residuals = accounts.flat_map { |account| account.values_at("balance_residual_cents", "debit_residual_cents", "credit_residual_cents") }.compact
        return "mismatch" if report.dig("page_coverage", "all_processed") == false
        short = residuals.any? { |value| value != 0 }
        closed_by_unclear = short && unclear_lines_close_totals?(revision)
        return "mismatch" if short && !closed_by_unclear
        return "count" if report.dig("row_census", "matches_reported") == false || accounts.any? { |account| account["row_count_matches"] == false }
        return "matches" if closed_by_unclear
        accounts.any? && accounts.all? { |account| account["arithmetic_balanced"] == true } ? "matches" : "unchecked"
      end

      # The extraction report sums only the lines whose kind was read. A line the reader could not classify still carries the
      # statement's own signed amount, so when every account's printed totals and balances close with those lines included,
      # nothing is missing: the unclear lines are questions about what each one was, asked on the line itself.
      def unclear_lines_close_totals?(revision)
        # She already said something is missing; the statement's arithmetic doesn't overrule her.
        return false if answer(revision) == "something_missing"
        accounts = revision.financial_source_accounts.to_a
        return false if accounts.empty?
        rows = FinancialSourceEvent.where(financial_extraction_revision: revision, row_kind: %w[posted unresolved])
          .pluck(:financial_source_account_id, :row_kind, :signed_amount_cents, :limitations)
        # An unresolved line with no stated reason is a doubt we can't name, so it fails closed too.
        return false if rows.any? { |_, kind, _, limits| kind == "unresolved" && (Array(limits).empty? || (Array(limits) - CLASSIFICATION_ONLY).any?) }
        amounts = rows.group_by(&:first).transform_values { |group| group.map { |row| row[2] } }
        accounts.all? do |account|
          signed = amounts.fetch(account.id, [])
          factor = { "asset" => 1, "liability" => -1 }[account.account_basis]
          printed = [ account.printed_debit_cents, account.printed_credit_cents, account.opening_balance_cents, account.closing_balance_cents ]
          next false if factor.nil? || printed.any?(&:nil?) || signed.any?(&:nil?)
          # Conflicting printed headers mean the stored totals may be the wrong ones, so they prove nothing.
          next false if Array(account.limitations).any? { |value| value.to_s.start_with?("conflicting_header_") }
          debit = signed.sum { |cents| [ -cents, 0 ].max }
          credit = signed.sum { |cents| [ cents, 0 ].max }
          debit == account.printed_debit_cents && credit == account.printed_credit_cents && account.closing_balance_cents - account.opening_balance_cents == factor * (credit - debit)
        end
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
      def latest(revision)
        SourceRevisionApproval.where(household_id: revision.household_id, financial_extraction_revision: revision).order(version_number: :desc).first
      end

      def answer(revision)
        approval = latest(revision)
        return unless approval
        approval.coverage_attestation["all_document_rows_accounted"] == true ? "nothing_missing" : "something_missing"
      end
    end
  end
end
