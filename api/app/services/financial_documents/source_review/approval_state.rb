module FinancialDocuments
  module SourceReview
    class ApprovalState
      def initialize(household, revision)
        @household, @revision = household, revision
        raise ArgumentError, "Revision is outside this household" unless revision.household_id == household.id
      end

      def call
        events = revision.financial_source_events.order(:position).to_a
        heads = SourceReviewHead.where(household: household, financial_source_event_id: events.map(&:id)).includes(approved_version: :source_account_identity_version).index_by(&:financial_source_event_id)
        account_heads = SourceAccountReviewHead.where(household: household, financial_source_account_id: revision.financial_source_accounts.select(:id)).includes(approved_version: :source_tracked_account).index_by(&:financial_source_account_id)
        row_versions = events.filter_map { |event| heads[event.id]&.approved_version }
        identities = account_heads.values.filter_map(&:approved_version)
        deficiencies = []
        deficiencies << "empty_source_history" if events.empty? || row_versions.none? { |row| row.disposition.in?(%w[include match]) } && !verified_zero_activity?(events, row_versions, identities)
        deficiencies << "unreviewed_source_rows" if row_versions.length != events.length
        deficiencies << "unreviewed_source_accounts" if identities.length != revision.financial_source_accounts.count
        deficiencies << "account_identity_changed" if row_versions.any? { |row| account_heads[row.financial_source_event.financial_source_account_id]&.approved_version_id != row.source_account_identity_version_id }
        source_report = revision.reconciliation
        pages = source_report.fetch("page_coverage", {})
        sheets = source_report.fetch("sheet_coverage", {})
        document_covered = pages["all_processed"] == true || sheets["expected"].to_i.positive? && Array(sheets["processed"]).sort == (0...sheets["expected"].to_i).to_a
        deficiencies << "document_page_or_sheet_coverage_unverified" unless document_covered
        deficiencies << "reported_row_census_mismatch" if source_report.dig("row_census", "matches_reported") == false
        deficiencies << "legacy_signed_history_unavailable" if revision.contract_version != AccountingContract::VERSION
        deficiencies << "source_unavailable" unless revision.financial_document_import&.source_available?
        reconciliation = reviewed_reconciliation(events, heads, account_heads)
        deficiencies << "account_reconciliation_incomplete" unless reconciliation[:accounts].all? { |account| account[:arithmetic_balanced] && account[:row_count_matches] != false }
        deficiencies << "split_purchase_funding_unresolved" if row_versions.any? { |row| row.expense? && row.purchase_amount_cents != row.signed_amount_cents.abs && !funding_linked?(row) }
        dependencies = self.class.dependencies(household, row_versions)
        deficiencies << "matched_source_fact_changed" if dependencies[:matches].any? { |match| !match[:current] }
        content = { source_version_ids: row_versions.map(&:id).sort, account_version_ids: identities.map(&:id).sort, dependencies: dependencies }
        { revision_id: revision.id, represented_rows: events.length, approved_rows: row_versions.length,
          pending_corrections: SourceReviewDraft.where(household: household, source_review_head_id: heads.values.map(&:id)).pending.count,
          content_digest: HouseholdFinance::Operations::PreparedOperation.fingerprint(content), **content,
          deficiencies: deficiencies.uniq, reconciliation: reconciliation }
      end

      # Exact dependencies are part of coverage, so a correction or changed
      # allocation cannot silently keep a prior coverage approval current.
      def self.dependencies(household, versions)
        ids = versions.map(&:id)
        matches = versions.select { |version| version.disposition == "match" }.map do |version|
          target = version.matched_version
          head_id = target&.source_review_head&.approved_version_id
          identity_id = target&.source_account_identity_version&.source_account_review_head&.approved_version_id
          { alias_version_id: version.id, target_version_id: target&.id, target_current_version_id: head_id,
            target_current_identity_version_id: identity_id,
            current: !!(target && head_id == target.id && identity_id == target.source_account_identity_version_id && target.disposition == "include") }
        end.sort_by { |match| match[:alias_version_id] }
        groups = EconomicLinker.current_versions(household).select { |group| group.source_economic_memberships.any? { |member| ids.include?(member.source_review_version_id) } }.map do |group|
          { id: group.id, digest: group.digest, members: group.source_economic_memberships.map do |member|
            version = member.source_review_version
            { version_id: version.id, role: member.role, allocation_cents: member.allocation_cents,
              current_version_id: version.source_review_head.approved_version_id,
              current_identity_version_id: version.source_account_identity_version.source_account_review_head.approved_version_id }
          end.sort_by { |member| [ member[:version_id], member[:role] ] } }
        end.sort_by { |group| group[:id] }
        { matches: matches, economic_groups: groups }
      end

      private

      attr_reader :household, :revision

      def verified_zero_activity?(events, versions, identities)
        return false unless versions.length == events.length && versions.all? { |row| row.disposition == "informational" }
        return false unless events.all? { |event| event.row_kind == "informational" || event.signed_amount_cents == 0 }
        return false unless identities.length == revision.financial_source_accounts.count && identities.any?
        identities.all? do |identity|
          facts = identity.statement_facts
          facts["period_start_on"].present? && facts["period_end_on"].present? &&
            facts["printed_debit_cents"] == 0 && facts["printed_credit_cents"] == 0 &&
            !facts["opening_balance_cents"].nil? && facts["opening_balance_cents"] == facts["closing_balance_cents"]
        end
      end

      def funding_linked?(version)
        EconomicLinker.valid_current_versions(household).any? { |group| group.kind == "purchase_funding" && group.source_economic_memberships.any? { |member| member.source_review_version_id == version.id && member.role == "purchase" } }
      end

      def reviewed_reconciliation(events, heads, account_heads)
        accounts = revision.financial_source_accounts.map do |account|
          identity = account_heads[account.id]&.approved_version
          facts = identity&.statement_facts.to_h.symbolize_keys
          account.attributes.symbolize_keys.slice(:source_key).merge(facts.except(:printed_row_count, :printed_row_count_basis)).merge(account_basis: identity&.source_tracked_account&.account_basis || "unknown", printed_row_count: nil, limitations: [])
        end
        rows = events.map do |event|
          approved = heads[event.id]&.approved_version
          posted = approved&.disposition.in?(%w[include match])
          { source_key: event.financial_source_account.source_key, row_kind: approved ? (posted ? "posted" : "informational") : "unresolved", signed_amount_cents: posted ? approved.signed_amount_cents : nil }
        end
        report = SourceReconciliation.new(contract_version: revision.contract_version, accounts: accounts, events: rows, coverage: revision.coverage).call
        report[:accounts].each do |account|
          source = revision.financial_source_accounts.find { |row| row.source_key == account[:source_key] }
          facts = account_heads[source.id]&.approved_version&.statement_facts.to_h
          printed = facts["printed_row_count"]
          count = facts["printed_row_count_basis"] == "all" ? account[:represented_rows] : account[:posted_rows]
          account[:limitations].delete("printed_row_count_unknown") unless printed.nil?
          account[:limitations] << "printed_row_census_mismatch" if printed && printed != count
          account.merge!(printed_row_count: printed, printed_row_count_basis: facts["printed_row_count_basis"], row_count_matches: printed.nil? ? nil : printed == count)
        end
        report
      end
    end
  end
end
