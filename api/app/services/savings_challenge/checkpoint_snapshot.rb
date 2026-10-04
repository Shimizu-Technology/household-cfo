module SavingsChallenge
  class CheckpointSnapshot
    VERSION = "savings_checkpoint_v1"

    def self.validate!(enrollment:, checkpoint:, snapshot:, previous: nil, historical: false)
      raise ArgumentError, "Invalid private checkpoint snapshot" unless snapshot.instance_of?(Hash)
      day = checkpoint.milestone_day
      cutoff = enrollment.starts_on + day - 1
      expected = { "calculation_version" => VERSION, "milestone_day" => day, "cutoff_on" => cutoff.iso8601,
        "time_zone" => enrollment.time_zone, "accepted_cohort_release_id" => enrollment.accepted_cohort_release_id }
      raise ArgumentError, "Checkpoint calendar or release identity changed" unless expected.all? { |key, value| snapshot[key] == value }
      raise ArgumentError, "Future checkpoints cannot be approved" if cutoff > enrollment.local_today
      financial = Inputs.integer!(snapshot.fetch("financial_approval_sequence"), minimum: 0, maximum: enrollment.approval_sequence)
      daily = Inputs.integer!(snapshot.fetch("daily_approval_sequence"), minimum: 0, maximum: SavingsDailyLedger.find_by(savings_enrollment: enrollment)&.sequence || 0)
      captured = Time.iso8601(snapshot.fetch("captured_at"))
      raise ArgumentError, "Checkpoint capture time is invalid" unless captured <= Time.current && captured.in_time_zone(enrollment.time_zone).to_date >= cutoff
      selection = snapshot.fetch("plan_selection")
      raise ArgumentError, "Checkpoint plan selection is invalid" unless selection.in?(%w[approved_by_cutoff retained_original explicit_correction])
      plan_id = snapshot.dig("savings", "accepted_plan_version_id")
      if selection == "approved_by_cutoff"
        raise ArgumentError, "A correction must preserve or explicitly correct its plan" if previous
        expected_plan = enrollment.savings_plan_versions.where(approval_sequence: ..financial).where("approved_at < ?", (cutoff + 1).in_time_zone(enrollment.time_zone)).order(approval_sequence: :desc).first
        raise ArgumentError, "Checkpoint target was not approved by its cutoff" unless plan_id == expected_plan&.id
      elsif !previous || (selection == "retained_original" && plan_id != previous.snapshot.dig("savings", "accepted_plan_version_id"))
        raise ArgumentError, "Checkpoint correction did not retain its approved target"
      end
      savings = Projection.new(enrollment, cutoff_on: cutoff, approval_sequence: financial, plan_version_id: plan_id,
        evidence_mode: :historical, frozen_evidence_quality: snapshot.dig("savings", "evidence_quality")).call.deep_stringify_keys
      # Legacy checkpoints predate reviewed allocations and retain their shape.
      if !snapshot.fetch("savings").key?("evidence_quality") && savings.fetch("evidence_quality").empty?
        savings.delete("evidence_quality")
      end
      unless historical
        current = Projection.new(enrollment, cutoff_on: cutoff, approval_sequence: financial, plan_version_id: plan_id, evidence_mode: :current).call.deep_stringify_keys
        current.delete("evidence_quality") unless savings.key?("evidence_quality")
        raise ArgumentError, "Checkpoint evidence quality changed; stage a new checkpoint" unless current == savings
      end
      baseline = CheckpointBaseline.resolve!(enrollment: enrollment, version_id: snapshot.dig("baseline", "version_id"))
      daily_summary = new(enrollment, milestone_day: day).send(:daily_snapshot, cutoff, daily).deep_stringify_keys
      raise ArgumentError, "Checkpoint calculations do not match approved histories" unless snapshot["savings"] == savings && snapshot["baseline"] == baseline && snapshot["daily"] == daily_summary
      status = snapshot.fetch("final_confirmation_status")
      raise ArgumentError, "Checkpoint final confirmation is invalid" unless day == 90 ? status.in?(%w[pending confirmed]) : status == "not_applicable"
      true
    rescue KeyError, TypeError, Date::Error
      raise ArgumentError, "Invalid private checkpoint snapshot"
    end

    def initialize(enrollment, milestone_day:, previous: nil, plan_version_id: nil, plan_correction: false,
      baseline_version_id: nil, final_confirmation: false)
      @enrollment, @day, @previous = enrollment, milestone_day, previous
      @plan_id, @plan_correction = plan_version_id, plan_correction
      @baseline_id, @final_confirmation = baseline_version_id, final_confirmation
    end

    def call
      raise ArgumentError, "Choose Day 30, 60 or 90" unless @day.in?([ 30, 60, 90 ])
      cutoff = @enrollment.starts_on + @day - 1
      raise ArgumentError, "Future milestones cannot be staged" if cutoff > @enrollment.local_today
      raise ArgumentError, "Final confirmation belongs only to Day 90" if @final_confirmation && @day != 90
      financial_sequence = @enrollment.approval_sequence
      daily_sequence = SavingsDailyLedger.find_by(savings_enrollment: @enrollment)&.sequence || 0
      plan = selected_plan(cutoff, financial_sequence)
      baseline_id = @baseline_id || (@previous ? @previous.snapshot.dig("baseline", "version_id") : plan&.financial_baseline_version_id)
      {
        calculation_version: VERSION, milestone_day: @day, cutoff_on: cutoff.iso8601,
        captured_at: Time.current.iso8601, time_zone: @enrollment.time_zone,
        accepted_cohort_release_id: @enrollment.accepted_cohort_release_id,
        financial_approval_sequence: financial_sequence, daily_approval_sequence: daily_sequence,
        plan_selection: @plan_correction ? "explicit_correction" : (@previous ? "retained_original" : "approved_by_cutoff"),
        savings: Projection.new(@enrollment, cutoff_on: cutoff, approval_sequence: financial_sequence, plan_version_id: plan&.id, evidence_mode: :current).call,
        baseline: CheckpointBaseline.resolve!(enrollment: @enrollment, version_id: baseline_id),
        daily: daily_snapshot(cutoff, daily_sequence),
        final_confirmation_status: @day == 90 ? (@final_confirmation ? "confirmed" : "pending") : "not_applicable"
      }.deep_stringify_keys
    end

    private

    def selected_plan(cutoff, sequence)
      plans = @enrollment.savings_plan_versions.where(approval_sequence: ..sequence)
      if @plan_correction
        raise ArgumentError, "Only an explained checkpoint correction may select another accepted plan" unless @previous && @plan_id
        plans.find(@plan_id)
      elsif @plan_id
        raise ArgumentError, "A checkpoint target must be selected by the server"
      elsif @previous
        id = @previous.snapshot.dig("savings", "accepted_plan_version_id")
        id && plans.find(id)
      else
        plans.where("approved_at < ?", (cutoff + 1).in_time_zone(@enrollment.time_zone)).order(approval_sequence: :desc).first
      end
    end

    def daily_snapshot(cutoff, sequence)
      purchases = SavingsDailyPurchaseVersion.where(savings_enrollment: @enrollment, daily_sequence: ..sequence)
        .select("DISTINCT ON (savings_daily_purchase_id) savings_daily_purchase_versions.*").order(:savings_daily_purchase_id, daily_sequence: :desc).to_a
        .select { |row| row.purchased_on <= cutoff && row.disposition == "purchase" }
      check_ins = SavingsDailyCheckInVersion.where(savings_enrollment: @enrollment, daily_sequence: ..sequence)
        .select("DISTINCT ON (savings_daily_check_in_id) savings_daily_check_in_versions.*").order(:savings_daily_check_in_id, daily_sequence: :desc)
        .includes(:savings_daily_check_in).to_a.select { |row| row.savings_daily_check_in.local_on <= cutoff }
      days = (cutoff - @enrollment.starts_on).to_i + 1
      no_spend = check_ins.count { |row| row.spending_state == "no_spend" }
      {
        scope: "participant_daily_reports", purchase_version_ids: purchases.map(&:id), check_in_version_ids: check_ins.map(&:id),
        approved_purchase_count: purchases.size, reported_spend_cents: purchases.any? || no_spend == days ? purchases.sum(&:amount_cents) : nil,
        completed_check_in_days: check_ins.size, no_spend_days: no_spend,
        unknown_reported_days: check_ins.count { |row| row.spending_state == "unknown" },
        unknown_unreported_days: days - check_ins.size, all_account_completeness: "unknown",
        no_spend_discrepancy_days: check_ins.count { |row| row.spending_state == "no_spend" && purchases.any? { |purchase| purchase.purchased_on == row.savings_daily_check_in.local_on } }
      }
    end
  end
end
