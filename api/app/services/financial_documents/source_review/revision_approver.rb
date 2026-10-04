module FinancialDocuments
  module SourceReview
    class RevisionApprover
      def initialize(domain, revision, input)
        @domain, @revision, @input = domain, revision, input
      end

      def call
        SourceAccountReviewHead.where(household: domain.household, financial_source_account_id: revision.financial_source_accounts.select(:id)).order(:id).lock.load
        SourceReviewHead.where(household: domain.household, financial_source_event_id: revision.financial_source_events.select(:id)).order(:id).lock.load
        state = ApprovalState.new(domain.household, revision).call
        raise Domain::StaleReview, "Source versions changed before coverage approval; nothing changed." unless state[:content_digest] == input[:expected_digest]
        deficiencies = state[:deficiencies].dup
        coverage = input[:coverage_attestation]
        attested = coverage[:accounts].index_by { |row| row[:source_account_id] }
        deficiencies << "document_rows_not_attested" unless coverage[:all_document_rows_accounted]
        revision.financial_source_accounts.each do |account|
          head = domain.account_heads.find_by(financial_source_account: account)
          identity = head&.approved_version
          declaration = attested[account.id]
          if !identity || !declaration || declaration[:identity_version_id] != identity.id || !declaration[:all_rows_accounted] ||
              identity.statement_facts["period_start_on"] != declaration[:period_start_on] || identity.statement_facts["period_end_on"] != declaration[:period_end_on]
            deficiencies << "account_period_or_row_coverage_not_attested"
          end
        end
        unless attested.keys.sort == revision.financial_source_accounts.pluck(:id).sort
          deficiencies << "account_attestation_scope_mismatch"
        end
        status = input[:requested_status]
        raise ArgumentError, "Choose complete or qualified source coverage" unless status.in?(%w[complete qualified])
        raise ArgumentError, "This source is incomplete: #{deficiencies.uniq.join(', ')}" if status == "complete" && deficiencies.any?
        prior = SourceRevisionApproval.where(household: domain.household, financial_extraction_revision: revision).order(version_number: :desc).first
        approved = SourceRevisionApproval.create!(household: domain.household, financial_extraction_revision: revision, approved_by_user: domain.user,
          version_number: prior&.version_number.to_i + 1, supersedes: prior, reason: input[:reason], digest: state[:content_digest],
          source_version_ids: state[:source_version_ids], account_version_ids: state[:account_version_ids], coverage_status: status,
          coverage_attestation: coverage, deficiencies: deficiencies.uniq, dependencies: state[:dependencies])
        import = revision.financial_document_import
        if import && import.metadata["source_accounting_revision_id"].to_i == revision.id
          pending = deficiencies.any? { |value| value.in?(%w[unreviewed_source_rows unreviewed_source_accounts account_identity_changed document_rows_not_attested account_period_or_row_coverage_not_attested account_attestation_scope_mismatch]) }
          import.update!(metadata: import.metadata.merge("source_accounting_review_pending" => pending, "source_revision_approval_id" => approved.id, "source_coverage_status" => status))
          HouseholdFinance::DocumentImportStatusReconciler.new(import).call
        end
        approved
      end

      private

      attr_reader :domain, :revision, :input
    end
  end
end
