module SavingsChallenge
  module Debt
    # A mapping identifies a reviewed liability account. It does not establish
    # that participant-entered APR/minimum/payment terms were printed in a file.
    class SourceMapping
      KEYS = %i[source_tracked_account_id source_account_identity_version_id source_revision_approval_id fingerprint].freeze
      def initialize(household) = @household = household

      def normalize(input)
        return nil if input.nil?
        raise ArgumentError, "Review the exact liability account mapping" unless input.is_a?(Hash)
        input = input.deep_symbolize_keys
        Inputs.keys!(input, required: KEYS)
        result = KEYS.first(3).to_h { |key| [ key, Inputs.id!(input[key]) ] }
        raise ArgumentError, "Review the current source fingerprint" unless input[:fingerprint].instance_of?(String) && input[:fingerprint].match?(/\A[0-9a-f]{64}\z/)
        result.merge(fingerprint: input[:fingerprint])
      end

      def resolve!(input, as_of_on:)
        return empty if input.nil?
        mapping = normalize(input)
        identity = SourceAccountIdentityVersion.where(household: @household).find(mapping[:source_account_identity_version_id])
        result = candidate(identity)
        raise HouseholdFinance::Operations::Base::StaleOperation, "The approved source identity or statement changed. Review the current liability mapping." unless result &&
          result[:source_tracked_account_id] == mapping[:source_tracked_account_id] && result[:source_revision_approval_id] == mapping[:source_revision_approval_id] && result[:fingerprint] == mapping[:fingerprint]
        raise ArgumentError, "Review terms as of the selected statement's exact end date" unless result[:statement_as_of_on] == as_of_on
        result.slice(:source_tracked_account_id, :source_account_identity_version_id, :source_revision_approval_id).merge(source_fingerprint: result[:fingerprint], source_snapshot: result[:snapshot])
      end

      def current?(version)
        return true unless version.source_account_identity_version_id
        resolve!({ source_tracked_account_id: version.source_tracked_account_id, source_account_identity_version_id: version.source_account_identity_version_id,
          source_revision_approval_id: version.source_revision_approval_id, fingerprint: version.source_fingerprint }, as_of_on: version.terms.fetch("as_of_on")) == values(version)
      rescue ArgumentError, ActiveRecord::RecordNotFound
        false
      end

      def values(record)
        { source_tracked_account_id: record.source_tracked_account_id, source_account_identity_version_id: record.source_account_identity_version_id,
          source_revision_approval_id: record.source_revision_approval_id, source_fingerprint: record.source_fingerprint, source_snapshot: record.source_snapshot }
      end

      def candidate(identity)
        head = identity.source_account_review_head.reload
        account = identity.source_tracked_account
        return unless head.approved_version_id == identity.id && account.household_id == @household.id && account.account_basis == "liability"
        source = head.financial_source_account
        revision = source.financial_extraction_revision
        approval = SourceRevisionApproval.where(household: @household, financial_extraction_revision: revision).order(version_number: :desc).first
        return unless approval && approval.digest == state(revision)[:content_digest]
        date = identity.statement_facts["period_end_on"]
        return unless date && latest_on(account.id) == date
        snapshot = { "identity_digest" => identity.digest, "revision_digest" => approval.digest,
          "statement_as_of_on" => date, "statement_closing_balance_cents" => identity.statement_facts["closing_balance_cents"], "account_label" => account.label }
        fingerprint = HouseholdFinance::Operations::PreparedOperation.fingerprint(identity_id: identity.id, approval_id: approval.id, tracked_account_id: account.id, snapshot: snapshot)
        closing = snapshot["statement_closing_balance_cents"]
        { source_tracked_account_id: account.id, source_account_identity_version_id: identity.id, source_revision_approval_id: approval.id,
          label: account.label, statement_as_of_on: date, fingerprint: fingerprint, snapshot: snapshot,
          proposed_terms: { balance_cents: closing && closing >= 0 ? closing : nil, as_of_on: date, minimum_payment_cents: nil, apr_bps: nil },
          qualifications: [ "APR, minimum and promotional terms remain participant-entered and unknown until reviewed.", *(closing && closing < 0 ? [ "The statement reports a credit balance; no amount owed is inferred." ] : []) ] }
      end

      def candidates
        SourceAccountIdentityVersion.where(household: @household).order(:id).filter_map { |identity| candidate(identity) }
      end

      private

      def state(revision) = FinancialDocuments::SourceReview::ApprovalState.new(@household, revision).call
      def empty = { source_tracked_account_id: nil, source_account_identity_version_id: nil, source_revision_approval_id: nil, source_fingerprint: nil, source_snapshot: {} }
      def latest_on(account_id)
        SourceAccountIdentityVersion.where(household: @household, source_tracked_account_id: account_id).includes(:source_account_review_head).filter_map do |identity|
          next unless identity.source_account_review_head.approved_version_id == identity.id
          revision = identity.source_account_review_head.financial_source_account.financial_extraction_revision
          approval = SourceRevisionApproval.where(financial_extraction_revision: revision).order(version_number: :desc).first
          identity.statement_facts["period_end_on"] if approval && approval.digest == state(revision)[:content_digest]
        end.max
      end
    end
  end
end
