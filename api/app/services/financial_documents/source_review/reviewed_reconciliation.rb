module FinancialDocuments
  module SourceReview
    # Extraction batches can name the same physical account differently. Only
    # participant-approved identities and full statement headers can reunite
    # those fragments; the immutable extraction and every row remain intact.
    class ReviewedReconciliation
      VERSION = "participant_statement_groups_v1"
      REQUIRED_HEADERS = %w[period_start_on period_end_on opening_balance_cents closing_balance_cents printed_debit_cents printed_credit_cents].freeze
      HEADERS = (REQUIRED_HEADERS + %w[printed_row_count printed_row_count_basis]).freeze

      def initialize(revision, events, heads, account_heads)
        @revision, @events, @heads, @account_heads = revision, events, heads, account_heads
      end

      def call
        source_keys = {}
        groups = revision.financial_source_accounts.order(:id).group_by { |account| confirmed_scope(account) || [ "source", account.id ] }
        accounts = groups.values.map do |fragments|
          account = reviewed_account(fragments)
          fragments.each { |fragment| source_keys[fragment.id] = account[:source_key] }
          account
        end
        rows = events.map do |event|
          approved = heads[event.id]&.approved_version
          posted = approved&.disposition.in?(%w[include match])
          { source_key: source_keys.fetch(event.financial_source_account_id), row_kind: approved ? (posted ? "posted" : "informational") : "unresolved",
            signed_amount_cents: posted ? approved.signed_amount_cents : nil }
        end
        report = SourceReconciliation.new(contract_version: revision.contract_version, accounts: accounts, events: rows, coverage: revision.coverage).call
        report[:accounts].each do |account|
          reviewed = accounts.find { |row| row[:source_key] == account[:source_key] }
          apply_census(account, reviewed)
        end
        report
      end

      private

      attr_reader :revision, :events, :heads, :account_heads

      def identity(account) = account_heads[account.id]&.approved_version

      def confirmed_scope(account)
        reviewed = identity(account)
        return unless reviewed && REQUIRED_HEADERS.all? { |key| !reviewed.statement_facts[key].nil? }

        [ "reviewed", reviewed.source_tracked_account_id, *reviewed.statement_facts.values_at("period_start_on", "period_end_on") ]
      end

      def reviewed_account(fragments)
        identities = fragments.map { |account| identity(account) }
        headers = identities.map { |reviewed| reviewed&.statement_facts.to_h }
        limitations = []
        facts = HEADERS.index_with do |key|
          values = headers.map { |header| header[key] }.uniq
          limitations << "conflicting_header_#{key}" if values.length > 1
          values.first
        end.symbolize_keys
        facts.merge(source_key: fragments.first.source_key, account_basis: identities.first&.source_tracked_account&.account_basis || "unknown",
          printed_row_count: nil, limitations: limitations, reviewed_printed_row_count: facts[:printed_row_count],
          source_account_ids: fragments.map(&:id), account_identity_version_ids: identities.compact.map(&:id),
          tracked_account_id: identities.first&.source_tracked_account_id)
      end

      def apply_census(account, reviewed)
        printed = reviewed[:reviewed_printed_row_count]
        basis = reviewed[:printed_row_count_basis]
        count = basis == "all" ? account[:represented_rows] : account[:posted_rows]
        account[:limitations].delete("printed_row_count_unknown") unless printed.nil?
        account[:limitations] << "printed_row_census_mismatch" if printed && printed != count
        account.merge!(printed_row_count: printed, printed_row_count_basis: basis, row_count_matches: printed.nil? ? nil : printed == count,
          source_account_ids: reviewed[:source_account_ids], account_identity_version_ids: reviewed[:account_identity_version_ids], tracked_account_id: reviewed[:tracked_account_id])
      end
    end
  end
end
