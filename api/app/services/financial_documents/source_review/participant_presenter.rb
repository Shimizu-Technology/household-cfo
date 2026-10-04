module FinancialDocuments
  module SourceReview
    # Reviewed facts are separate from immutable extraction and erasable evidence.
    class ParticipantPresenter
      def initialize(household, revision, user: nil)
        @household, @revision, @user = household, revision, user
      end

      def context(event_ids:)
        heads = SourceReviewHead.where(household: household, financial_source_event_id: event_ids)
          .includes(:approved_version, source_review_drafts: []).index_by(&:financial_source_event_id)
        account_heads = SourceAccountReviewHead.where(household: household, financial_source_account_id: revision.financial_source_accounts.select(:id))
          .includes(approved_version: :source_tracked_account).index_by(&:financial_source_account_id)
        approval = SourceRevisionApproval.where(household: household, financial_extraction_revision: revision).order(version_number: :desc).first
        state = ApprovalState.new(household, revision).call
        {
          schema_version: 1,
          actor_scope: { user_id: @user&.id, household_id: household.id },
          rows: event_ids.index_with do |id|
            head = heads[id]
            { head: head_state(head), approved: head&.approved_version && record(head.approved_version),
              pending: head&.source_review_drafts&.pending&.first&.then { |draft| record(draft) } }
          end,
          accounts: revision.financial_source_accounts.order(:id).map do |account|
            head = account_heads[account.id]
            { source_account_id: account.id, head: head_state(head), approved: head&.approved_version && record(head.approved_version) }
          end,
          coverage: state,
          approved_coverage: approval && { id: approval.id, digest: approval.digest, status: approval.coverage_status,
            current: approval.digest == state[:content_digest], deficiencies: approval.deficiencies },
          economic_groups: EconomicLinker.current_versions(household).select { |group| group.source_economic_memberships.any? { |member| event_ids.include?(member.source_review_version.financial_source_event.id) } }.map do |group|
            { id: group.source_economic_group_id, head: head_state(group.source_economic_group),
              approved: { id: group.id, kind: group.kind, digest: group.digest, version_number: group.version_number, reason: group.reason,
                current: group.source_economic_memberships.all? { |member| member.source_review_version.source_review_head.approved_version_id == member.source_review_version_id && member.source_review_version.source_account_identity_version.source_account_review_head.approved_version_id == member.source_review_version.source_account_identity_version_id },
                members: group.source_economic_memberships.map { |member| { role: member.role, allocation_cents: member.allocation_cents, record: record(member.source_review_version) } } } }
          end,
          categories: household.budget_categories.active.order(:sort_order, :id).pluck(:id, :name).map { |id, name| { id: id, name: name } }
        }
      end

      def record(subject, include_matched_target: true)
        case subject
        when SourceReviewDraft
          subject.attributes.slice("id", "status", "lock_version", "digest", "facts", "projection", "reason", "base_version_id", "base_head_lock_version").merge(
            recognized_account: recognized_account(subject.facts["source_account_identity_version_id"]),
            matched_target: include_matched_target ? matched_target(subject.facts["matched_version_id"]) : nil)
        when SourceReviewVersion
          { id: subject.id, digest: subject.digest, version_number: subject.version_number, facts: subject.reviewed_facts,
            projection: subject.projection, reason: subject.reason,
            source: { document_import_id: subject.financial_source_event.financial_extraction_revision.financial_document_import_id,
              filename: subject.financial_source_event.financial_extraction_revision.financial_document_import&.filename,
              locator: subject.financial_source_event.locator, source_available: subject.financial_source_event.financial_extraction_revision.financial_document_import&.source_available? == true },
            actual: actual(subject), recognized_account: recognized_account(subject.source_account_identity_version_id),
            current: current_version?(subject), matched_target: include_matched_target ? matched_target(subject.matched_version_id) : nil }
        when SourceAccountIdentityVersion
          { id: subject.id, digest: subject.digest, version_number: subject.version_number, statement_facts: subject.statement_facts,
            tracked_account: { id: subject.source_tracked_account_id, label: subject.source_tracked_account.label,
              account_basis: subject.source_tracked_account.account_basis, account_id: subject.source_tracked_account.account_id } }
        else
          { id: subject.id, digest: subject.try(:digest) }
        end
      end

      private

      attr_reader :household, :revision

      def head_state(head)
        { id: head&.id, approved_version_id: head&.approved_version_id, lock_version: head&.lock_version || 0 }
      end

      def recognized_account(identity_id)
        identity = SourceAccountIdentityVersion.where(household: household).find_by(id: identity_id)
        return unless identity
        { identity_version_id: identity.id, tracked_account_id: identity.source_tracked_account_id,
          label: identity.source_tracked_account.label, account_basis: identity.source_tracked_account.account_basis,
          account_id: identity.source_tracked_account.account_id, current: identity.source_account_review_head.approved_version_id == identity.id }
      end

      def matched_target(version_id)
        target = SourceReviewVersion.where(household: household).find_by(id: version_id)
        record(target, include_matched_target: false) if target
      end

      def current_version?(version)
        version.source_review_head.approved_version_id == version.id &&
          version.source_account_identity_version.source_account_review_head.approved_version_id == version.source_account_identity_version_id
      end

      def actual(version)
        transactions = household.household_transactions.where(financial_source_event: version.financial_source_event, status: %w[confirmed reconciled]).order(:id).limit(2).to_a
        return unless transactions.one?
        transaction = transactions.first
        { id: transaction.id, amount_cents: transaction.total_amount_cents,
          digest: ProjectionCorrector.snapshot_digest(transaction) }
      end
    end
  end
end
