# frozen_string_literal: true

module FinancialDocuments
  class SourceReconciliation
    VERSION = "source_reconciliation_v1"

    def initialize(accounting)
      @accounting = accounting.deep_symbolize_keys
    end

    def call
      events = accounting.fetch(:events)
      coverage = accounting.fetch(:coverage)
      represented = events.length
      reported = coverage[:reported_row_count]
      page_count = coverage[:expected_page_count]
      processed = Array(coverage[:processed_pages]).uniq.sort
      page_complete = page_count ? processed == (1..page_count).to_a : nil
      reports = accounting.fetch(:accounts).map { |account| account_report(account, events.select { |event| event[:source_key] == account[:source_key] }) }
      {
        calculation_version: VERSION,
        status: "unreviewed",
        participant_approved: false,
        row_census: { represented: represented, reported: reported, matches_reported: reported.nil? ? nil : reported == represented, by_kind: events.group_by { |event| event[:row_kind] }.transform_values(&:length) },
        page_coverage: { expected: page_count, processed: processed, all_processed: page_complete },
        sheet_coverage: { expected: coverage[:expected_sheet_count], processed: coverage[:processed_sheets] },
        account_coverage: { represented: reports.length, expected: nil, verified: false },
        accounts: reports,
        limitations: [ ("legacy_expense_only_contract" if accounting[:contract_version] == AccountingContract::LEGACY_VERSION), ("reported_row_census_unknown" if reported.nil?), ("reported_row_census_mismatch" if reported && reported != represented), ("page_coverage_incomplete" if page_complete == false), "account_coverage_unverified", "coverage_and_classifications_require_participant_review" ].compact
      }
    end

    private

    attr_reader :accounting

    def account_report(account, events)
      posted = events.select { |event| event[:row_kind] == "posted" && !event[:signed_amount_cents].nil? }
      debit = posted.sum { |event| [ -event[:signed_amount_cents], 0 ].max }
      credit = posted.sum { |event| [ event[:signed_amount_cents], 0 ].max }
      opening = account[:opening_balance_cents]
      closing = account[:closing_balance_cents]
      factor = { "asset" => 1, "liability" => -1 }[account[:account_basis]]
      residual = opening && closing && factor ? closing - opening - factor * (credit - debit) : nil
      unresolved = events.count { |event| event[:row_kind] == "unresolved" }
      limitations = Array(account[:limitations])
      limitations += [ ("statement_period_unknown" unless account[:period_start_on] && account[:period_end_on]), ("opening_or_closing_balance_unknown" if opening.nil? || closing.nil?), ("printed_debit_total_unknown" if account[:printed_debit_cents].nil?), ("printed_credit_total_unknown" if account[:printed_credit_cents].nil?), ("printed_row_count_unknown" if account[:printed_row_count].nil?), ("printed_row_census_mismatch" if account[:printed_row_count] && account[:printed_row_count] != events.length), ("unresolved_rows_present" if unresolved.positive?) ].compact
      {
        source_key: account[:source_key], account_basis: account[:account_basis], period_start_on: account[:period_start_on], period_end_on: account[:period_end_on],
        represented_rows: events.length, posted_rows: posted.length, unresolved_rows: unresolved,
        printed_row_count: account[:printed_row_count], row_count_matches: account[:printed_row_count].nil? ? nil : account[:printed_row_count] == events.length,
        debit_cents: debit, credit_cents: credit, printed_debit_cents: account[:printed_debit_cents], printed_credit_cents: account[:printed_credit_cents],
        debit_residual_cents: account[:printed_debit_cents].nil? ? nil : account[:printed_debit_cents] - debit,
        credit_residual_cents: account[:printed_credit_cents].nil? ? nil : account[:printed_credit_cents] - credit,
        opening_balance_cents: opening, closing_balance_cents: closing, balance_residual_cents: residual,
        arithmetic_balanced: residual == 0 && unresolved.zero? && limitations.none? { |value| value.start_with?("conflicting_header_") } && account[:printed_debit_cents] == debit && account[:printed_credit_cents] == credit,
        limitations: limitations.uniq
      }
    end
  end
end
