module FinancialDocuments
  # Deletion only: account-kind answers do not approve any statement lines.
  # Keep the broader approved_values? rule for reprocessing and all other callers.
  class UnapprovedStatementAccounts
    def self.removable?(document)
      ApplicationRecord.connection.select_value(
        ApplicationRecord.sanitize_sql_array([ "SELECT statement_account_answers_removable(?)", document.id ])
      ) == true
    end

    SNAPSHOT_REVISION_KEYS = %w[revision_ids requested_revision_ids dependency_revision_ids].freeze

    # A saved spending snapshot names the readings it was built from, by id inside
    # JSON. Deleting such a file would leave that snapshot unreadable.
    def self.named_by_spending_snapshot?(document)
      ids = document.financial_extraction_revisions.pluck(:id)
      return false if ids.empty?

      # Named binds: the "?" in the path expression is jsonpath's filter, not a placeholder.
      clause = SNAPSHOT_REVISION_KEYS.map { |key| "jsonb_path_exists(snapshot, '$.**.#{key}[*] ? (@ == $id)', jsonb_build_object('id', CAST(:revision_id AS bigint)))" }.join(" OR ")
      ids.any? { |id| FinancialBaselineVersion.where(household_id: document.household_id).where(clause, revision_id: id).exists? }
    end

    def self.remove!(document)
      raise ArgumentError, "This statement already has approved lines." unless removable?(document)

      accounts = FinancialSourceAccount.where(financial_extraction_revision_id: document.financial_extraction_revisions.select(:id))
      heads = SourceAccountReviewHead.where(financial_source_account_id: accounts.select(:id)).lock.to_a
      heads.reject! do |head|
        head.source_account_identity_versions.any? do |version|
          ApplicationRecord.connection.select_value(ApplicationRecord.sanitize_sql_array([ "SELECT source_account_history_in_use(?)", version.source_tracked_account_id ]))
        end
      end
      versions = SourceAccountIdentityVersion.where(source_account_review_head_id: heads.map(&:id))
      tracked_ids = versions.distinct.pluck(:source_tracked_account_id)
      SourceAccountReviewHead.where(id: heads.map(&:id)).update_all(approved_version_id: nil)
      # Newer versions point to older ones. Remove only this file's answer history.
      versions.order(version_number: :desc, id: :desc).pluck(:id).each { |id| SourceAccountIdentityVersion.where(id: id).delete_all }
      SourceAccountReviewHead.where(id: heads.map(&:id)).delete_all
      SourceTrackedAccount.where(id: tracked_ids, account_id: nil).where("NOT source_account_history_in_use(id)").where.not(id: SourceAccountIdentityVersion.select(:source_tracked_account_id)).delete_all
    end
  end
end
