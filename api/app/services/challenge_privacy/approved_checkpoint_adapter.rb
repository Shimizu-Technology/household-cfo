module ChallengePrivacy
  # Only this private envelope contains participant/checkpoint identities. The
  # fixed export consumes its band and never publishes the provenance envelope.
  class ApprovedCheckpointAdapter
    def snapshot(enrollment, checkpoint_day:, cutoff_on:)
      day = Integer(checkpoint_day)
      cutoff = Date.iso8601(cutoff_on.to_s)
      validate_cutoff!(enrollment.cohort, checkpoint_day: day, cutoff_on: cutoff)
      personal_cutoff = enrollment.starts_on + day - 1
      raise Access::Denied, "Participant window precedes the scheduled cohort window" if personal_cutoff < cutoff
      return unapproved(enrollment, day, cutoff, "withdrawn") if enrollment.status == "withdrawn"
      return unapproved(enrollment, day, cutoff, "late_window") if personal_cutoff > cutoff

      head = SavingsCheckpoint.find_by(savings_enrollment: enrollment, milestone_day: day)
      version = head&.current_version
      return unapproved(enrollment, day, cutoff, "unknown") unless version
      unless version.savings_checkpoint_id == head.id && version.savings_enrollment_id == enrollment.id &&
        version.version_number.positive? && version.approved_at && version.approved_by_user_id == enrollment.user_id
        raise Access::Denied, "The approved checkpoint identity is invalid"
      end
      SavingsChallenge::CheckpointSnapshot.validate!(enrollment: enrollment, checkpoint: head,
        snapshot: version.snapshot, previous: version.previous_version)
      { enrollment_id: enrollment.id, checkpoint_id: head.id, checkpoint_version: version.version_number,
        cutoff_on: cutoff.iso8601, digest: fingerprint(version_id: version.id, checkpoint_id: head.id,
          enrollment_id: enrollment.id, version_number: version.version_number, snapshot: version.snapshot), band: band(version.snapshot, day) }
    rescue ArgumentError, TypeError, ActiveRecord::RecordNotFound
      raise Access::Denied, "The approved checkpoint cannot be verified"
    end

    def validate_cutoff!(cohort, checkpoint_day:, cutoff_on:)
      unless checkpoint_day.in?([ 30, 60, 90 ]) && cohort.starts_on && cutoff_on == cohort.starts_on + checkpoint_day - 1
        raise Access::Denied, "Invalid scheduled cohort checkpoint"
      end
      previous = ChallengeSponsorExport.where(cohort: cohort, policy_version: SponsorExports::POLICY_VERSION).order(:checkpoint_day).first
      if previous && previous.resolved_cutoff_on - previous.checkpoint_day + 1 != cohort.starts_on
        raise Access::Denied, "The sealed cohort checkpoint calendar changed"
      end
      true
    end

    private

    def fingerprint(value) = HouseholdFinance::Operations::PreparedOperation.fingerprint(value)
    def unapproved(enrollment, day, cutoff, reason)
      { enrollment_id: enrollment.id, checkpoint_id: "unapproved:#{enrollment.id}:#{day}", checkpoint_version: nil,
        cutoff_on: cutoff.iso8601, band: reason, digest: fingerprint(enrollment_id: enrollment.id, milestone_day: day,
          cohort_id: enrollment.cohort_id, accepted_release_id: enrollment.accepted_cohort_release_id,
          starts_on: enrollment.starts_on.iso8601, cohort_starts_on: enrollment.cohort.starts_on.iso8601,
          cutoff_on: cutoff.iso8601, status: enrollment.status, unapproved_reason: reason) }
    end
    def band(snapshot, day)
      savings = snapshot.fetch("savings")
      return "no_target" if savings["target_cents"].nil?
      return "custom_target" unless savings["target_cents"] == 50_000
      return "unknown" unless savings["reporting_known"] == true
      return "final_pending" if day == 90 && snapshot["final_confirmation_status"] != "confirmed"
      savings["achieved"] == true ? "at_target" : "below_target"
    end
  end
end
