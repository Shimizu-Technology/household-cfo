# frozen_string_literal: true

module FinancialDocuments
  class SourceAccountingPersister
    def initialize(document_import, attempt:, accounting:, structured_spreadsheet: false)
      @document_import = document_import
      @attempt = attempt
      @accounting = accounting.deep_symbolize_keys
      @structured_spreadsheet = structured_spreadsheet
    end

    # Caller holds the import lock and has fenced the attempt. Facts are append
    # only; staging expenses is a separate projection after this revision exists.
    def call
      ApplicationRecord.transaction { persist }
    end

    private

    def persist
      reconciliation = SourceReconciliation.new(accounting).call
      revision = FinancialExtractionRevision.create!(
        household: document_import.household, financial_document_import: document_import,
        financial_document_import_attempt: attempt,
        revision_number: FinancialExtractionRevision.where(financial_document_import: document_import).maximum(:revision_number).to_i + 1,
        contract_version: accounting.fetch(:contract_version), payload_digest: Digest::SHA256.hexdigest(JSON.generate(accounting)),
        source_document_identity: Digest::SHA256.hexdigest("household/#{document_import.household_id}/import/#{document_import.id}"),
        coverage: accounting.fetch(:coverage), reconciliation: reconciliation
      )
      accounts = accounting.fetch(:accounts).index_with do |attributes|
        record = FinancialSourceAccount.create!(attributes.except(:evidence).merge(household: document_import.household, financial_extraction_revision: revision))
        record.create_financial_source_evidence!(household: document_import.household, payload: attributes[:evidence]) if attributes[:evidence].present?
        record
      end.to_h { |attributes, record| [ attributes.fetch(:source_key), record ] }
      events = accounting.fetch(:events).map do |attributes|
        record = FinancialSourceEvent.create!(attributes.except(:evidence, :source_key).merge(household: document_import.household, financial_extraction_revision: revision, financial_source_account: accounts.fetch(attributes.fetch(:source_key))))
        record.create_financial_source_evidence!(household: document_import.household, payload: attributes[:evidence]) if attributes[:evidence].present?
        record
      end
      { revision: revision, events: events, reconciliation: reconciliation, transaction_drafts: expense_projections(events) }
    end

    private

    attr_reader :document_import, :attempt, :accounting, :structured_spreadsheet

    def expense_projections(events)
      events.select(&:expense_projection_eligible?).map do |event|
        evidence = event.financial_source_evidence&.payload.to_h.deep_symbolize_keys
        structured = structured_spreadsheet && event.locator.to_h.key?("sheet_index")
        confidence = structured ? StructuredSpreadsheetExtractor::STRUCTURED_TRANSACTION_CONFIDENCE : evidence[:confidence]
        splits = Array(evidence[:splits])
        if structured && splits.empty?
          splits = [ { amount_cents: event.expense_amount_cents, category_name: evidence[:category_name], stack_key: evidence[:stack_key],
            notes: evidence[:evidence], confidence: confidence, row_number: event.locator["row"] } ]
        end
        {
          financial_source_event_id: event.id,
          occurred_on: event.posted_on.iso8601,
          merchant: evidence[:merchant].presence || "Source transaction",
          total_amount_cents: event.expense_amount_cents,
          total_amount: HouseholdFinance::Money.dollars(event.expense_amount_cents),
          category_name: evidence[:category_name], stack_key: evidence[:stack_key],
          raw_description: evidence[:raw_description], evidence: evidence[:evidence],
          external_id: event.row_identity, confidence: confidence, splits: splits
        }
      end
    end
  end
end
