require "csv"

module ChallengePrivacy
  class SponsorExports
    POLICY_VERSION = "fixed_coarse_min5_v1".freeze
    BANDS = %w[at_target below_target unknown final_pending custom_target no_target late_window withdrawn].freeze
    # Production adapters must read immutable approved S07 checkpoints, verify
    # pinned versions/cutoff, and classify without returning raw financial data.
    class CheckpointAdapter
      def validate_cutoff!(cohort, checkpoint_day:, cutoff_on:)
        ApprovedCheckpointAdapter.new.validate_cutoff!(cohort, checkpoint_day: checkpoint_day, cutoff_on: cutoff_on)
      end
      def snapshot(enrollment, checkpoint_day:, cutoff_on:)
        ApprovedCheckpointAdapter.new.snapshot(enrollment, checkpoint_day: checkpoint_day, cutoff_on: cutoff_on)
      end
    end

    def initialize(cohort, user:, adapter: CheckpointAdapter.new) = (@cohort, @user, @adapter = cohort, user, adapter)
    def approve(checkpoint_day:, resolved_cutoff_on:, policy_version: POLICY_VERSION)
      raise ArgumentError, "Use only fixed Day 30, 60 or 90 exports" unless [ 30, 60, 90 ].include?(checkpoint_day) && policy_version == POLICY_VERSION
      cutoff = Date.iso8601(resolved_cutoff_on.to_s)
      raise ArgumentError, "A scheduled cutoff cannot be in the future" if cutoff > Date.current
      ApplicationRecord.transaction do
        lock_scope!
        identity = { cohort: @cohort, checkpoint_day: checkpoint_day, policy_version: policy_version }
        existing = ChallengeSponsorExport.find_by(identity)
        if existing
          raise Access::Denied, "This checkpoint already has a different fixed cutoff" unless existing.resolved_cutoff_on == cutoff
          return read_locked(existing)
        end
        @adapter.validate_cutoff!(@cohort, checkpoint_day: checkpoint_day, cutoff_on: cutoff) if @adapter.respond_to?(:validate_cutoff!)
        provenance = current_provenance
        raise Access::Denied, "Sponsor reporting is limited to the thirty-person pilot" if provenance[:participants].length > 30
        observations = eligible_enrollments.map { |enrollment| checkpoint(enrollment, checkpoint_day, cutoff) }
        prior = ChallengeSponsorExport.where(cohort: @cohort, policy_version: policy_version).order(:checkpoint_day).last
        raise Access::Denied, "Fixed sponsor checkpoints must be sealed in increasing day order" if prior && prior.checkpoint_day >= checkpoint_day
        raise Access::Denied, "Each participant requires a distinct checkpoint identity" unless observations.pluck(:checkpoint_id).uniq.length == observations.length
        transitions = prior && changed_observations(prior.private_provenance["observations"], observations)
        report = build_report(observations, provenance, checkpoint_day, cutoff, suppress_changes: transitions && transitions.between?(1, 4))
        sealed = provenance.merge(observations: observations)
        record = ChallengeSponsorExport.create!(identity.merge(approved_by_user: @user, resolved_cutoff_on: cutoff, private_provenance: sealed,
          report: report, digest: fingerprint(report), created_at: Time.current))
        record.report
      end
    end

    def read(export_id)
      ApplicationRecord.transaction do
        lock_scope!
        read_locked(ChallengeSponsorExport.where(cohort: @cohort).find(export_id))
      end
    end

    def csv(export_id)
      report = read(export_id)
      CSV.generate do |csv|
        csv << %w[metric band count_range qualification]
        Array(report["bands"]).each { |row| csv << [ "checkpoint_progress", row["band"], row["count_range"], report["qualification"] ].map { |value| self.class.escape_cell(value) } }
        csv << [ "active_consent_denominator", "", report["active_consent_count_range"], report["qualification"] ].map { |value| self.class.escape_cell(value) }
      end
    end

    def self.escape_cell(value)
      string = value.to_s
      string.match?(/\A[\s\u0000-\u001f]*[=+@-]/) ? "'#{string}" : string
    end

    private
    def fingerprint(value) = HouseholdFinance::Operations::PreparedOperation.fingerprint(value)
    def enrollments = SavingsEnrollment.where(cohort: @cohort).order(:household_id, :id)
    def eligible_enrollments
      enrollments.select do |enrollment|
        grant = ChallengePrivacyGrant.find_by(savings_enrollment: enrollment, kind: "sponsor_aggregate", recipient_user_id: nil)
        grant&.active? && participant_current?(enrollment) && runtime_current?(enrollment)
      end
    end
    def participant_current?(enrollment)
      Access.participant_current!(enrollment)
      true
    rescue Access::Denied
      false
    end
    def runtime_current?(enrollment)
      membership = enrollment.cohort.cohort_memberships.find_by(user_id: enrollment.user_id, role: "participant")
      membership && SavingsChallenge::AccessPolicy.runtime_allowed?(user: enrollment.user, membership: membership) == true
    end
    def lock_scope!
      # All participant mutations take household before cohort. Freeze that same
      # complete household set before acquiring the cohort/export identity lock.
      ids = enrollments.reorder(nil).distinct.pluck(:household_id).sort
      Household.where(id: ids).order(:id).lock.load
      @cohort.lock!
      raise Access::Denied, "Participant scope changed; retry the fixed report review" unless ids == enrollments.reorder(nil).distinct.pluck(:household_id).sort
      Access.staff!(@cohort, @user, export: true)
      unless @cohort.savings_challenge_enabled && !@cohort.savings_challenge_release_hold && @cohort.status.in?(%w[enrolling active completed])
        raise Access::Denied, "Sponsor reporting is unavailable for this program right now"
      end
    end
    def current_provenance
      { cohort_starts_on: @cohort.starts_on&.iso8601, participants: enrollments.map do |enrollment|
        grant = ChallengePrivacyGrant.find_by(savings_enrollment: enrollment, kind: "sponsor_aggregate", recipient_user_id: nil)
        { enrollment_id: enrollment.id, user_id: enrollment.user_id, household_id: enrollment.household_id, status: enrollment.status,
          membership_id: enrollment.cohort.cohort_memberships.find_by(user_id: enrollment.user_id, role: "participant")&.id,
          current_participant: participant_current?(enrollment), runtime_current: runtime_current?(enrollment) == true, grant_id: grant&.id, grant_lock_version: grant&.lock_version,
          consent_active: grant&.active? == true, consent_expiry: grant&.expires_at&.iso8601 }
      end }
    end
    def read_locked(record)
      unless record.private_provenance.except("observations") == current_provenance.deep_stringify_keys
        raise Access::Denied, "Consent or participation changed; this fixed report is unavailable and cannot be rebuilt"
      end
      record.report
    end
    def checkpoint(enrollment, day, cutoff)
      value = @adapter.snapshot(enrollment, checkpoint_day: day, cutoff_on: cutoff).to_h.deep_symbolize_keys
      unless value.keys.sort == %i[band checkpoint_id checkpoint_version cutoff_on digest enrollment_id] && value[:enrollment_id] == enrollment.id &&
        checkpoint_identity?(value, enrollment, day) &&
        value[:cutoff_on] == cutoff.iso8601 && value[:digest].is_a?(String) && value[:digest].match?(/\A[0-9a-f]{64}\z/) && BANDS.include?(value[:band])
        raise Access::Denied, "The approved checkpoint adapter is incomplete"
      end
      value
    end
    def checkpoint_identity?(value, enrollment, day)
      approved = value[:checkpoint_id].is_a?(Integer) && value[:checkpoint_id].positive? &&
        value[:checkpoint_version].is_a?(Integer) && value[:checkpoint_version].positive?
      unapproved = value[:checkpoint_id] == "unapproved:#{enrollment.id}:#{day}" && value[:checkpoint_version].nil? &&
        value[:band].in?(%w[unknown late_window withdrawn])
      approved || unapproved
    end
    def changed_observations(prior, current)
      before = Array(prior).index_by { |row| row["enrollment_id"] }
      after = current.index_by { |row| row[:enrollment_id] }
      (before.keys | after.keys).count { |id| before[id]&.dig("band") != after[id]&.dig(:band) }
    end
    def range(count) = count.zero? ? "0" : "#{count / 5 * 5}-#{count / 5 * 5 + 4}"
    def build_report(observations, provenance, day, cutoff, suppress_changes:)
      counts = BANDS.index_with { |band| observations.count { |row| row[:band] == band } }
      total = observations.length
      suppress = total < 5 || suppress_changes || counts.values.any? { |count| count.positive? && (count < 5 || (total - count).between?(1, 4)) }
      enrolled = provenance[:participants].length
      denominator_safe = total >= 5 && !(enrolled - total).between?(1, 4)
      suppress ||= !denominator_safe
      { schema_version: 1, policy_version: POLICY_VERSION, checkpoint_day: day, cutoff_on: cutoff.iso8601,
        active_consent_count_range: denominator_safe ? range(total) : "suppressed",
        bands: suppress ? [] : counts.filter_map { |band, count| { band: band, count_range: range(count) } if count.positive? },
        suppressed: suppress, qualification: "Participant checkpoint bands; active sponsor consent only, with separate household allocations rather than summed household money. Missing, pending final confirmation, custom or absent targets, late windows and withdrawals are distinct states. Custom or absent target bands do not establish known savings; late windows and withdrawals do not establish a checkpoint result. Counts are ranges; suppressed cells and complements are unavailable. This uncontrolled pilot does not establish causal effectiveness or guarantee anonymity.",
        exact_money_totals_included: false, roster_included: false, dynamic_filters_supported: false }
    end
  end
end
