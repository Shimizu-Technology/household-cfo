module FinancialDocuments
  module SourceReview
    # Internal participant/domain reader. A controller still authorizes its
    # audience; this is not a sponsor/coach serializer.
    class ApprovedSourceReader
      def initialize(household)
        @household = household
      end

      def call(revision_ids:, current_financial_picture: false)
        revisions = FinancialExtractionRevision.where(household: household, id: Array(revision_ids).uniq).order(:id).to_a
        raise ActiveRecord::RecordNotFound unless revisions.length == Array(revision_ids).uniq.length
        if current_financial_picture
          revisions.each { |revision| HouseholdFinance::FinancialGenerationGuard.source!(revision.financial_document_import) }
        end
        groups = EconomicLinker.valid_current_versions(household)
        heads = SourceReviewHead.where(household: household, financial_source_event_id: FinancialSourceEvent.where(financial_extraction_revision_id: revisions.map(&:id)))
          .includes(approved_version: [ :source_account_identity_version, :source_review_head ])
        versions = heads.filter_map(&:approved_version).sort_by(&:id)
        canonical = versions.filter_map do |version|
          if version.disposition == "include"
            version
          elsif version.disposition == "match"
            target = version.matched_version
            target if version.source_account_identity_version.source_account_review_head.approved_version_id == version.source_account_identity_version_id && target && target.source_review_head.approved_version_id == target.id && target.disposition == "include" &&
              target.source_account_identity_version.source_account_review_head.approved_version_id == target.source_account_identity_version_id
          end
        end.uniq(&:id).sort_by(&:id)
        groups = groups.select { |group| group.source_economic_memberships.any? { |member| (versions + canonical).any? { |version| version.id == member.source_review_version_id } } }
        rows = versions.map { |version| row(version, groups) }
        canonical_rows = canonical.map { |version| row(version, groups) }
        dependency_revision_ids = (canonical.map { |version| version.financial_source_event.financial_extraction_revision_id } +
          groups.flat_map { |group| group.source_economic_memberships.map { |member| member.source_review_version.financial_source_event.financial_extraction_revision_id } }).uniq - revisions.map(&:id)
        dependencies = FinancialExtractionRevision.where(household: household, id: dependency_revision_ids).order(:id).to_a
        if current_financial_picture
          dependencies.each { |revision| HouseholdFinance::FinancialGenerationGuard.source!(revision.financial_document_import) }
        end
        statuses = (revisions + dependencies).map do |revision|
          state = ApprovalState.new(household, revision).call
          last = SourceRevisionApproval.where(household: household, financial_extraction_revision: revision).order(version_number: :desc).first
          current = last && last.digest == state[:content_digest]
          { id: revision.id, content_digest: state[:content_digest], approval_id: last&.id,
            coverage_status: last ? (current ? last.coverage_status : "stale") : "unreviewed",
            participant_approved: !!current, state: state, latest_extraction_revision_id: revision.financial_document_import&.metadata&.dig("source_accounting_revision_id"), source_available: revision.financial_document_import&.source_available? == true }
        end
        { rows: rows, canonical_rows: canonical_rows, requested_revision_ids: revisions.map(&:id), dependency_revision_ids: dependency_revision_ids.sort, revisions: statuses, economic_groups: groups.map { |group| { id: group.id, kind: group.kind, digest: group.digest,
          members: group.source_economic_memberships.map { |member| { version_id: member.source_review_version_id, role: member.role, allocation_cents: member.allocation_cents } } } },
          digest: HouseholdFinance::Operations::PreparedOperation.fingerprint(rows: rows.map { |row| [ row[:id], row[:digest], row[:account_identity_current], row[:spending_eligible] ] }, canonical_rows: canonical_rows.map { |row| [ row[:id], row[:digest], row[:account_identity_current], row[:spending_eligible] ] }, economic_groups: groups.map { |group| [ group.id, group.digest ] }, revisions: statuses.map { |row| [ row[:id], row[:content_digest], row[:coverage_status], row[:approval_id] ] }) }
      end

      private

      attr_reader :household

      def row(version, groups)
        funded = groups.any? { |group| group.kind == "purchase_funding" && group.source_economic_memberships.any? { |member| member.source_review_version_id == version.id && member.role == "purchase" } }
        identity = version.source_account_identity_version
        current_identity = identity.source_account_review_head.approved_version_id == identity.id
        { id: version.id, head_id: version.source_review_head_id, event_id: version.financial_source_event.id,
          revision_id: version.financial_source_event.financial_extraction_revision_id, digest: version.digest,
          disposition: version.disposition, event_type: version.event_type, signed_amount_cents: version.signed_amount_cents,
          purchase_amount_cents: version.purchase_amount_cents, posted_on: version.posted_on&.iso8601, authorized_on: version.authorized_on&.iso8601,
          merchant: version.merchant, category: version.category_snapshot, matched_version_id: version.matched_version_id,
          account_identity_version_id: identity.id, tracked_account_id: identity.source_tracked_account_id,
          account_basis: identity.source_tracked_account.account_basis, account_identity_current: current_identity,
          spending_eligible: current_identity && version.expense? && (version.purchase_amount_cents == version.signed_amount_cents.abs || funded),
          requires_funding_link: version.expense? && version.purchase_amount_cents != version.signed_amount_cents.abs && !funded }
      end
    end
  end
end
