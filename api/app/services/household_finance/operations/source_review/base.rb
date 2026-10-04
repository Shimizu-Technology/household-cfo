module HouseholdFinance
  module Operations
    module SourceReview
      class Base < Operations::Base
        ACTOR_REQUIRED = true
        SENSITIVE_AUDIT = true
        VERSION = 1
        REPLAY_CLASSES = [ SourceReviewDraft, SourceReviewVersion, SourceAccountIdentityVersion, SourceRevisionApproval, SourceEconomicGroupVersion, SourceProjectionRevision ].freeze

        def initialize(household, user: nil)
          super(household)
          @domain = FinancialDocuments::SourceReview::Domain.new(household, user: user)
        end

        def prepare(raw_input)
          ApplicationRecord.transaction do
            household.lock!
            domain.authorize!
            require_tool!
            super
          end
        end

        def execute!(prepared, source:)
          ApplicationRecord.transaction do
            household.lock!
            super
          end
        end

        def authorize_replay!(subject)
          raise ArgumentError, "Source operation subject is unavailable" unless REPLAY_CLASSES.any? { |klass| subject.is_a?(klass) }
          ApplicationRecord.transaction do
            household.lock!
            domain.authorize!(subject)
            require_tool!
          end
        end

        private

        attr_reader :domain

        def normalize(input) = domain.normalize(self.class::ACTION, input)
        def ensure_plan!(_input) = nil

        def subject_for(input, lock:)
          case self.class::ACTION
          when "stage" then domain.source_event(input[:event_id])
          when "approve", "cancel" then domain.drafts.find(input[:draft_id])
          when "account_link" then domain.source_account(input[:source_account_id])
          when "revision_approve" then domain.revision(input[:revision_id])
          when "economic_link" then input[:group_id] ? domain.groups.find(input[:group_id]) : household
          when "project" then domain.versions.find(input[:version_id])
          end
        end

        def canonical_snapshot(_subject, input, lock:) = domain.snapshot(self.class::ACTION, input)

        def validate_execution!(_subject, _input, prepared:, source:)
          domain.authorize!
          require_tool!
        end

        def require_tool! = CohortReleases::OperationAccess.require!(household: household, user: domain.user, key: self.class::KEY, membership: release_membership)

        def mutate!(_subject, input, prepared:) = domain.execute(self.class::ACTION, input)

        def predicted_after(_before, input)
          proof(input)
        end

        def canonical_after_snapshot(subject, input, prepared:)
          proof(input, subject)
        end

        def verify_after!(predicted, actual)
          raise ArgumentError, "The source review result did not match the approved request; nothing changed." unless predicted.deep_stringify_keys == actual.deep_stringify_keys
          true
        end

        def proof(input, subject = nil)
          case self.class::ACTION
          when "stage"
            { action: "stage", event_id: subject ? subject.source_review_head.financial_source_event_id : input[:event_id],
              facts_digest: domain.digest(subject ? subject.facts : input[:facts]), projection_digest: domain.digest(subject ? subject.projection : input[:projection]), reason: subject ? subject.reason : input[:reason] }
          when "approve"
            draft = domain.drafts.find(input[:draft_id])
            { action: "approve", facts_digest: domain.digest(subject ? subject.reviewed_facts : draft.facts), projection_digest: domain.digest(subject ? subject.projection : draft.projection), reason: subject ? subject.reason : draft.reason }
          when "cancel"
            { action: "cancel", draft_id: subject&.id || input[:draft_id], status: subject&.status || "cancelled" }
          when "account_link"
            account = subject&.source_tracked_account
            { action: "account_link", source_account_id: subject ? subject.source_account_review_head.financial_source_account_id : input[:source_account_id],
              label: account&.label || input[:label], account_basis: account&.account_basis || input[:account_basis], account_id: account ? account.account_id : input[:account_id],
              statement_facts_digest: domain.digest(subject ? subject.statement_facts : input[:statement_facts]), reason: subject&.reason || input[:reason] }
          when "revision_approve"
            { action: "revision_approve", content_digest: subject&.digest || input[:expected_digest], coverage_status: subject&.coverage_status || input[:requested_status],
              coverage_digest: domain.digest(subject ? subject.coverage_attestation : input[:coverage_attestation]), reason: subject&.reason || input[:reason] }
          when "economic_link"
            members = subject ? subject.source_economic_memberships.map { |row| { source_review_version_id: row.source_review_version_id, role: row.role, allocation_cents: row.allocation_cents } }.sort_by { |row| [ row[:source_review_version_id], row[:role] ] } : input[:members]
            { action: "economic_link", kind: subject&.kind || input[:kind], members_digest: domain.digest(members), reason: subject&.reason || input[:reason] }
          when "project"
            version = domain.versions.find(input[:version_id])
            replacement = subject&.replacement_transaction
            expected = input[:projection][:action].in?(%w[create replace]) ? { amount_cents: version.purchase_amount_cents, posted_on: version.posted_on.iso8601, merchant: version.merchant, category_id: version.budget_category_id } : nil
            actual = replacement && { amount_cents: replacement.total_amount_cents, posted_on: replacement.occurred_on.iso8601, merchant: replacement.merchant, category_id: replacement.transaction_splits.sole.budget_category_id }
            { action: "project", version_id: subject&.source_review_version_id || version.id, projection_action: subject&.action || input[:projection][:action],
              previous_transaction_id: subject ? subject.previous_transaction_id : input[:projection][:transaction_id], replacement: subject ? actual : expected }
          end
        end

        def stale_message = "Source review changed. Refresh the current versions; nothing changed."
      end
    end
  end
end
