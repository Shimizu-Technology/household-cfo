module SavingsChallenge
  class CheckpointBaseline
    def self.resolve!(enrollment:, version_id:)
      return { "version_id" => nil, "coverage_status" => "not_provided", "source_evidence_status" => "unlinked" } if version_id.nil?

      version = FinancialBaselineVersion.where(household_id: enrollment.household_id).joins(:financial_baseline_head)
        .where(financial_baseline_heads: { participant_user_id: enrollment.user_id }).find(version_id)
      published_ids = approved_history_ids(version.financial_baseline_head)
      unless version.approved_by_user_id == enrollment.user_id && version.calculation_version == FinancialBaselines::Preview::CALCULATION_VERSION &&
          published_ids.include?(version.id) && version.digest == HouseholdFinance::Operations::PreparedOperation.fingerprint(version.snapshot)
        raise ArgumentError, "The approved baseline does not match its frozen evidence"
      end
      { "version_id" => version.id, "digest" => version.digest, "coverage_status" => version.coverage_status,
        "source_evidence_status" => "frozen_approved_baseline", "window_start_on" => version.window_start_on.iso8601,
        "window_end_on" => version.window_end_on.iso8601,
        "supported_complete_calendar_month_count" => version.snapshot.fetch("supported_complete_calendar_month_count"),
        "observed_spending_known" => version.snapshot.fetch("observed_spending_known") }
    end

    def self.approved_history_ids(head)
      ids = Set.new
      id = head.approved_version_id
      while id
        raise ArgumentError, "Baseline approval history is invalid or exceeds its bounded chain" if ids.include?(id) || ids.size >= 10_000
        ids << id
        id = head.financial_baseline_versions.find(id).supersedes_id
      end
      ids
    end
    private_class_method :approved_history_ids
  end
end
