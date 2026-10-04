# frozen_string_literal: true

module FinancialDocuments
  # Internal serializer only. The controller must authorize the household,
  # revision and raw-evidence grant before calling it; it issues no source URLs.
  class SourceAccountingPresenter
    def initialize(revision, include_evidence: false)
      @revision = revision
      @include_evidence = include_evidence
    end

    def summary
      {
        id: revision.id, contract_version: revision.contract_version,
        revision_number: revision.revision_number, payload_digest: revision.payload_digest,
        source_document_identity: revision.source_document_identity,
        financial_document_import_id: revision.financial_document_import_id,
        coverage: revision.coverage, reconciliation: revision.reconciliation,
        review_state: "unreviewed", participant_approved: false,
        source_available: revision.financial_document_import&.source_available? == true,
        created_at: revision.created_at.iso8601,
        accounts: revision.financial_source_accounts.includes(:financial_source_evidence).order(:id).map { |record| account(record) }
      }
    end

    def event(record)
      ensure_revision!(record)
      result = record.attributes.symbolize_keys.slice(:id, :financial_source_account_id, :financial_extraction_revision_id, :position, :row_identity, :row_kind, :event_type, :signed_amount_cents, :expense_amount_cents, :locator, :funding_components, :limitations)
      result.merge!(posted_on: record.posted_on&.iso8601, authorized_on: record.authorized_on&.iso8601,
        review_state: "unreviewed", expense_projection_eligible: record.expense_projection_eligible?, evidence_available: record.financial_source_evidence.present?)
      result[:evidence] = record.financial_source_evidence&.payload if include_evidence
      result
    end

    private

    attr_reader :revision, :include_evidence

    def account(record)
      ensure_revision!(record)
      result = record.attributes.symbolize_keys.slice(:id, :source_key, :account_basis, :opening_balance_cents, :closing_balance_cents, :printed_debit_cents, :printed_credit_cents, :printed_row_count, :limitations)
      result.merge!(period_start_on: record.period_start_on&.iso8601, period_end_on: record.period_end_on&.iso8601,
        evidence_available: record.financial_source_evidence.present?)
      result[:evidence] = record.financial_source_evidence&.payload if include_evidence
      result
    end

    def ensure_revision!(record)
      raise ArgumentError, "Source record is outside the authorized revision" unless record.financial_extraction_revision_id == revision.id && record.household_id == revision.household_id
    end
  end
end
