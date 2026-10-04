module SavingsChallenge
  class ParticipantSerializer
    def self.record(record)
      case record
      when SavingsEnrollment
        record.attributes.slice("id", "cohort_id", "accepted_cohort_release_id", "starts_on", "ends_on", "time_zone", "status", "policy_version", "late_start_accepted", "current_accepted_plan_version_id", "approval_sequence", "lock_version")
      when SavingsEntry
        record.attributes.slice("id", "current_approved_version_id", "lock_version").merge(
          "current_approved_version" => record.current_approved_version && self.record(record.current_approved_version))
      when SavingsEntryVersion
        evidence = EvidenceProjection.new(record.savings_enrollment, sequence: record.savings_enrollment.approval_sequence, cutoff_on: record.savings_enrollment.local_today).call[:quality]
          .find { |row| row["entry_version_id"] == record.id }
        record.attributes.slice("id", "savings_entry_id", "previous_version_id", "version_number", "approval_sequence", "signed_cents", "effective_on", "currency", "funding_source", "evidence_supported_cents", "reason", "approved_at")
          .merge("evidence_supported_cents" => evidence&.fetch("supported_cents") || 0, "evidence_status" => evidence&.fetch("status") || "not_linked",
            "evidence_version_id" => evidence&.fetch("version_id"), "evidence_head_lock_version" => SavingsEvidenceAllocation.find_by(savings_entry_version: record)&.lock_version || 0)
      when SavingsEvidenceVersion
        record.attributes.slice("id", "savings_evidence_allocation_id", "previous_version_id", "version_number", "approval_sequence", "state", "supported_cents", "digest", "reason", "approved_at", "proof_snapshot")
          .merge("proof_display" => evidence_display(record))
      when SavingsEntryDraft
        record.attributes.slice("id", "savings_entry_id", "base_version_id", "base_entry_lock_version", "approved_version_id", "signed_cents", "effective_on", "funding_source", "reason", "status", "lock_version")
      when SavingsPlanVersion
        plan_context(record.attributes.slice("id", "previous_version_id", "version_number", "approval_sequence", "target_cents", "reason", "approved_at", "financial_baseline_version_id", "baseline_digest", "spending_changes"), record)
      when SavingsPlanDraft
        plan_context(record.attributes.slice("id", "base_plan_version_id", "approved_plan_version_id", "target_cents", "reason", "status", "lock_version", "financial_baseline_version_id", "baseline_digest", "spending_changes"), record)
      when SavingsZeroAttestation
        record.attributes.slice("id", "cutoff_on", "approval_sequence", "previous_attestation_id", "approved_at")
      else
        raise ArgumentError, "Unsupported private savings record"
      end
    end

    def self.evidence_display(record)
      record.proof_snapshot.flat_map do |proof|
        ids = Array(proof["dependencies"]).filter_map { |row| row["version_id"] }
        SourceReviewVersion.where(household_id: record.savings_enrollment.household_id, id: ids)
          .includes(source_account_identity_version: :source_tracked_account, source_review_head: { financial_source_event: { financial_extraction_revision: :financial_document_import } }).order(:id).map do |version|
          document = version.financial_source_event.financial_extraction_revision.financial_document_import
          { "merchant" => version.merchant, "posted_on" => version.posted_on, "account_label" => version.source_tracked_account.label,
            "filename" => document.filename, "source_available" => document.source_available?,
            "movement_kind" => proof["group_version_id"] ? "reviewed_asset_transfer" : "reviewed_income", "amount_cents" => proof["amount_cents"] }
        end
      end
    end

    def self.plan_context(values, record)
      baseline = record.financial_baseline_version
      names = record.savings_enrollment.household.budget_categories.where(id: record.spending_changes.filter_map { |row| row["budget_category_id"] }).pluck(:id, :name).to_h
      values.merge("spending_changes" => record.spending_changes.map { |row| row.merge("category_name" => names[row["budget_category_id"]]) },
        "baseline_context" => baseline && { "window_start_on" => baseline.snapshot["window_start_on"], "window_end_on" => baseline.snapshot["window_end_on"], "coverage_status" => baseline.coverage_status })
    end

    def self.calendar(enrollment)
      today = enrollment.local_today
      phase = today < enrollment.starts_on ? "upcoming" : (today > enrollment.ends_on ? "window_ended" : "active")
      {
        time_zone: enrollment.time_zone, local_today: today, starts_on: enrollment.starts_on, ends_on: enrollment.ends_on,
        phase: phase, day: today < enrollment.starts_on ? nil : [ (today - enrollment.starts_on).to_i + 1, 90 ].min,
        checkpoints: [ 30, 60, 90 ].to_h { |day| [ day, (enrollment.starts_on + day - 1).iso8601 ] }
      }
    end
  end
end
