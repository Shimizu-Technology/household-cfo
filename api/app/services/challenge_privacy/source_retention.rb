module ChallengePrivacy
  class SourceRetention
    DISCLOSURE_VERSION = "personal_end_plus_30_days_v1".freeze
    def self.available?(source, at: Time.current)
      return false unless source.source_available?
      uses = FinancialSourceUse.where(financial_document_import: source)
      return true unless uses.exists? # Existing originals have no new implicit lease.
      uses.where(revoked_at: nil).where("expires_at > ?", at).exists?
    end

    def initialize(household, user:) = (@household, @user = household, user)
    def describe(source)
      ApplicationRecord.transaction do
        @household.lock!
        describe_locked(source)
      end
    end

    def describe_locked(source)
      authorize_owner!(source)
      uses = FinancialSourceUse.where(financial_document_import: source).order(:id)
      { document_import_id: source.id, source_available: self.class.available?(source),
        latest_authorized_expiry: uses.where(revoked_at: nil).maximum(:expires_at)&.iso8601,
        affected_uses: uses.map { |use| { id: use.id, enrollment_id: use.savings_enrollment_id, expires_at: use.expires_at.iso8601, revoked: use.revoked_at.present? } },
        approved_financial_records_retained: true, downloaded_copies_retrievable: false,
        provider_backup_retention_verified: false }
    end
    private :describe_locked

    def authorize_owner!(source)
      actor = User.lock.find_by(id: @user&.id)
      membership = @household.household_memberships.lock.find_by(user_id: actor&.id)
      allowed = actor&.participant? && !actor.revoked? && source.household_id == @household.id && membership&.role.in?(%w[owner partner])
      raise Access::Denied, "This source is unavailable" unless allowed
    end

    def authorize!(source, enrollment, disclosure_version:, expected_expires_at:)
      authorize_owner!(source)
      Access.participant!(@household, @user, enrollment, active: true)
      source.lock!
      expiry = enrollment.ends_on.in_time_zone(enrollment.time_zone).end_of_day + 30.days
      unless source.source_available? && disclosure_version == DISCLOSURE_VERSION && expected_expires_at == expiry.iso8601 && expiry > Time.current
        raise ArgumentError, "Review the exact disclosed source-use expiry"
      end
      use = FinancialSourceUse.find_or_initialize_by(financial_document_import: source, savings_enrollment: enrollment)
      use.assign_attributes(household: @household, participant_user_id: enrollment.user_id,
        expires_at: expiry, revoked_at: nil, disclosure_version: disclosure_version, authorized_at: Time.current)
      use.save!
      use
    end

    # No storage call or queue admission here. The durable primary outbox remains
    # recoverable even when the root-owned worker is unavailable.
    def revoke_all!(source)
      authorize_owner!(source)
      source.lock!
      FinancialSourceUse.where(financial_document_import: source, revoked_at: nil).update_all(revoked_at: Time.current, lock_version: Arel.sql("lock_version + 1"), updated_at: Time.current)
      cleanup = FinancialDocumentSourceCleanup.request!(source, user: @user)
      unless source.source_deleted_at
        status = source.applied? || source.partially_applied? ? source.status : "source_deleted"
        source.update!(source_deleted_at: Time.current, source_deleted_by_user: @user, status: status)
      end
      FinancialDocuments::SourceEvidenceEraser.call(source)
      { source: source, cleanup: cleanup }
    end

    def expire!(source)
      ApplicationRecord.transaction do
        @household.lock!
        raise Access::Denied, "This source is unavailable" unless source.household_id == @household.id
        source.lock!
        return if self.class.available?(source) || !FinancialSourceUse.where(financial_document_import: source).exists?
        # System expiry has no participant gate; it can only shorten an already
        # explicitly disclosed expired lease, never extend or read a source.
        FinancialSourceUse.where(financial_document_import: source, revoked_at: nil).update_all(revoked_at: Time.current, lock_version: Arel.sql("lock_version + 1"), updated_at: Time.current)
        cleanup = FinancialDocumentSourceCleanup.request!(source, user: nil)
        source.update!(source_deleted_at: source.source_deleted_at || Time.current, status: source.applied? || source.partially_applied? ? source.status : "source_deleted")
        FinancialDocuments::SourceEvidenceEraser.call(source)
        cleanup
      end
    end
  end
end
