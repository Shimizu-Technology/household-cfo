# frozen_string_literal: true

module FinancialDocuments
  class SourceReviewPage
    class InvalidPage < StandardError; end
    class StaleRevision < StandardError; end
    FILTERS = %w[all posted informational unresolved].freeze
    PER_PAGE = 50

    def initialize(document_import, revision_id:, page: "1", per_page: "50", filter: "all")
      @import = document_import
      @revision_id = revision_id.to_s
      @page = positive_integer(page)
      raise InvalidPage, "Review pages contain 50 rows" unless per_page.to_s == PER_PAGE.to_s

      @filter = filter.to_s
      raise InvalidPage, "Unknown review filter" unless FILTERS.include?(@filter)
    end

    def call
      revision = @import.financial_extraction_revisions.order(revision_number: :desc, id: :desc).first
      raise StaleRevision, "The extraction changed. Reload this document before reviewing it." unless revision && revision.id.to_s == @revision_id

      presenter = SourceAccountingPresenter.new(revision, include_evidence: @import.source_available?)
      all = revision.financial_source_events.where(household_id: @import.household_id)
      grouped = all.group(:row_kind).count
      scope = @filter == "all" ? all : all.where(row_kind: @filter)
      total = scope.count
      pages = [ (total.to_f / PER_PAGE).ceil, 1 ].max
      raise InvalidPage, "Review page is outside this result" if @page > pages

      events = scope.includes(:financial_source_evidence).order(:position, :id).offset((@page - 1) * PER_PAGE).limit(PER_PAGE).to_a
      drafts = @import.transaction_drafts.where(household_id: @import.household_id, financial_source_event_id: events.map(&:id))
        .includes(:budget_category, :matched_transaction, transaction_draft_splits: :budget_category, transaction_draft_matches: { household_transaction: { transaction_splits: :budget_category } })
        .order(:id).group_by(&:financial_source_event_id)
      summary = presenter.summary
      {
        schema_version: 1, document_import_id: @import.id, revision: summary, accounts: summary.fetch(:accounts),
        review_pending: @import.metadata["source_accounting_review_pending"] == true,
        counts: { all: grouped.values.sum, posted: grouped.fetch("posted", 0), informational: grouped.fetch("informational", 0), unresolved: grouped.fetch("unresolved", 0),
          pending_transaction_drafts: @import.transaction_drafts.pending.count,
          resolved_transaction_drafts: @import.transaction_drafts.where.not(status: "pending").count },
        pagination: { page: @page, per_page: PER_PAGE, total_count: total, total_pages: pages, has_previous: @page > 1, has_next: @page < pages },
        events: events.map { |event| presenter.event(event).merge(transaction_draft: yield(drafts[event.id]&.last)) }
      }
    end

    private

    def positive_integer(value)
      raise InvalidPage, "Invalid review page" unless value.to_s.match?(/\A[1-9]\d*\z/)

      value.to_s.to_i
    end
  end
end
