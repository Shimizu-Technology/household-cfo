module FinancialBaselines
  # Private participant reader; never a sponsor/coach serializer.
  class Reader
    def initialize(household, user: nil)
      @household, @user = household, user
    end

    def current
      authorized do
        head = heads.first
        version = head&.approved_version
        return { head_id: head&.id, lock_version: head&.lock_version || 0, approved_version: nil } unless version
        freshness = begin
          preview = Preview.new(household, user: user).call(version.snapshot.fetch("request"))
          { needs_revision: preview[:digest] != version.digest, current_dataset_digest: preview[:digest], current_deficiencies: preview[:deficiencies] }
        rescue ActiveRecord::RecordNotFound, ArgumentError
          { needs_revision: true, current_dataset_digest: nil, current_deficiencies: [ "current_baseline_inputs_unavailable" ] }
        end
        { head_id: head.id, lock_version: head.lock_version, approved_version: version, **freshness }
      end
    end

    def find(version_id)
      authorized { FinancialBaselineVersion.where(household: household, financial_baseline_head_id: heads.select(:id)).find(version_id) }
    end

    private

    attr_reader :household, :user
    def heads = FinancialBaselineHead.where(household: household, participant_user: user)

    def authorized
      ApplicationRecord.transaction do
        household.lock!
        FinancialDocuments::SourceReview::Domain.new(household, user: user).authorize!
        yield
      end
    end
  end
end
