require "test_helper"

# Opt-in local verification only. No participant statements or transaction
# fixtures are stored in Git. Failure messages deliberately omit private rows.
if ENV["NATIVE_STATEMENT_PRIVATE_DIR"].present? && ENV["NATIVE_STATEMENT_ORACLE_DIR"].present?
  class FinancialDocumentsNativeStatementPrivateTest < ActiveSupport::TestCase
    COUNTS = { "1-Apple-Cash" => 419, "2-WF-5" => 121, "3-WF-4" => 111, "4-WF-3" => 124, "5-WF-2" => 90, "6-WF-1" => 69 }.freeze

    test "all six native statements match an independent geometry oracle without deduplicating rows" do
      financial_count = 0
      informational_count = 0
      period_count = 0
      COUNTS.each do |stem, expected_count|
        oracle = JSON.parse(File.read(File.join(ENV.fetch("NATIVE_STATEMENT_ORACLE_DIR"), "#{stem}-geometry-oracle.json")))
        file_path = File.join(ENV.fetch("NATIVE_STATEMENT_PRIVATE_DIR"), "#{stem}.pdf")
        result = extract_local_statement(file_path)
        assert result.success?, "#{stem}: native rejection #{result.error}"
        source = result.data.fetch(:source_accounting)
        financial = source.fetch(:events).reject { |event| event[:row_kind] == "informational" }
        expected = oracle.fetch("rows").reject { |row| row["informational"] }
        actual_keys = financial.map { |row| [ row.dig(:locator, :page), row[:posted_on].iso8601, row[:signed_amount_cents] ] }.tally
        oracle_keys = expected.map { |row| [ row.fetch("page"), row.fetch("posted_on"), row.fetch("signed_amount_cents") ] }.tally
        assert actual_keys == oracle_keys, "#{stem}: physical page/date/signed-cent multiset mismatch"
        assert_equal expected_count, financial.size, "#{stem}: row count mismatch"
        assert_equal oracle.fetch("page_count"), result.metadata[:page_count]
        source.fetch(:accounts).each do |account|
          rows = expected.select { |row| row["posted_on"].between?(account[:period_start_on].iso8601, account[:period_end_on].iso8601) }
          credits = rows.sum { |row| [ row["signed_amount_cents"], 0 ].max }
          debits = rows.sum { |row| [ -row["signed_amount_cents"], 0 ].max }
          assert credits == account[:printed_credit_cents], "#{stem}: printed credit mismatch"
          assert debits == account[:printed_debit_cents], "#{stem}: printed debit mismatch"
          assert account[:opening_balance_cents] + credits - debits == account[:closing_balance_cents], "#{stem}: balance mismatch"
          assert_match(/\A\*{4}\d{4}\z/, account.dig(:evidence, :masked_identifier))
        end
        assert_empty result.data[:transaction_drafts]
        assert_empty result.data[:items]
        financial_count += financial.size
        informational_count += source[:events].size - financial.size
        period_count += source[:accounts].size
      end
      assert_equal 934, financial_count
      assert_equal 33, informational_count
      assert_equal 18, period_count
    end

    private

    def extract_local_statement(file_path)
      configured = S3Service.method(:configured?)
      download = S3Service.method(:download_to_io)
      S3Service.define_singleton_method(:configured?) { true }
      S3Service.define_singleton_method(:download_to_io) do |_key, io|
        File.open(file_path, "rb") { |source| IO.copy_stream(source, io) }
        true
      end
      document_import = FinancialDocumentImport.new(document_kind: "statement", filename: File.basename(file_path), content_type: "application/pdf", s3_key: "local-test-placeholder")
      extractor = FinancialDocuments::Extractor.new(api_key: "")
      extractor.define_singleton_method(:batched_pdf_result) { |*_args| raise "native must not call the provider" }
      extractor.call(document_import)
    ensure
      S3Service.define_singleton_method(:configured?, configured) if configured
      S3Service.define_singleton_method(:download_to_io, download) if download
    end
  end
end
