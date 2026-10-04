module FinancialDocuments
  module SourceReview
    class ProjectionCorrector
      def self.snapshot_digest(transaction)
        HouseholdFinance::Operations::PreparedOperation.fingerprint({ transaction: transaction.attributes.slice("id", "household_id", "financial_source_event_id", "status", "occurred_on", "merchant", "total_amount_cents"),
          splits: transaction.transaction_splits.order(:id).map { |split| [ split.id, split.budget_category_id, split.amount_cents ] } })
      end

      def initialize(domain, version, input)
        @domain, @version, @input = domain, version, input
      end

      def call
        action = input.fetch(:action)
        return if action == "none"
        raise ArgumentError, "This approved version already has a financial projection; append a source correction first" if version.source_projection_revision
        event = version.financial_source_event
        previous = domain.household.household_transactions.lock.find(input[:transaction_id]) if input[:transaction_id]
        if previous
          unless previous.financial_source_event_id == event.id && previous.status.in?(%w[confirmed reconciled]) && self.class.snapshot_digest(previous) == input[:expected_digest]
            raise Domain::StaleReview, "The linked financial transaction changed or is outside this source row."
          end
        end
        if action == "create" && domain.household.household_transactions.where(financial_source_event: event, status: %w[confirmed reconciled]).exists?
          raise ArgumentError, "This source row already has approved spending. Review an explicit replacement."
        end
        replacement = nil
        if action.in?(%w[create replace])
          raise ArgumentError, "Only an included outflow expense can create positive spending" unless version.expense?
          raise ArgumentError, "Review a specific active category before creating spending" unless version.budget_category&.active?
          if version.purchase_amount_cents != version.signed_amount_cents.abs
            linked = EconomicLinker.valid_current_versions(domain.household).any? { |group| group.kind == "purchase_funding" && group.source_economic_memberships.any? { |member| member.source_review_version_id == version.id && member.role == "purchase" } }
            raise ArgumentError, "Resolve split funding before projecting its full purchase" unless linked
          end
          raise ArgumentError, "The expense date is outside supported budget years" unless HouseholdFinance::AnnualBudgetManager.supported_year?(version.posted_on.year)
          manager = HouseholdFinance::AnnualBudgetManager.new(domain.household, year: version.posted_on.year)
          replacement = domain.household.household_transactions.create!(budget_period: manager.current_period_for(version.posted_on),
            financial_source_event: event, source_import: event.financial_extraction_revision.financial_document_import,
            occurred_on: version.posted_on, merchant: version.merchant, total_amount_cents: version.purchase_amount_cents,
            source_type: "statement", status: "confirmed", metadata: { source_review_version_id: version.id })
          replacement.transaction_splits.create!(budget_category: version.budget_category, amount_cents: version.purchase_amount_cents)
          replacement.validate_split_total!
        end
        previous&.update!(status: "ignored")
        if replacement
          domain.household.transaction_drafts.pending.where(financial_source_event: event).order(:id).lock.each do |draft|
            draft.update!(status: "corrected", confirmed_transaction: replacement, draft_payload: draft.draft_payload.merge("source_review_version_id" => version.id))
          end
        end
        SourceProjectionRevision.create!(household: domain.household, source_review_version: version, previous_transaction: previous, replacement_transaction: replacement,
          action: action, previous_snapshot_digest: input[:expected_digest], approved_by_user: domain.user, reason: input[:reason].presence || version.reason,
          digest: domain.digest(version_id: version.id, projection: input))
      end

      private

      attr_reader :domain, :version, :input
    end
  end
end
