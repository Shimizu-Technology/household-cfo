# frozen_string_literal: true

module CohortRollouts
  class Eligibility
    OPEN_COHORT_STATUSES = %w[draft enrolling active].freeze

    def initialize(cohort:)
      @cohort = cohort
    end

    def plan_blockers(target_release:, waves:)
      blockers = []
      blockers << "Completed and archived cohorts are read-only." unless cohort.status.in?(OPEN_COHORT_STATUSES)
      blockers.concat(release_blockers(target_release, require_latest: true, label: "target"))
      blockers.concat(wave_blockers(waves))
      blockers
    end

    def advance_blockers(rollout)
      blockers = boundary_blockers(rollout)
      unless rollout.status.in?(%w[planned active])
        blockers << "Only a planned or active rollout can advance."
        return blockers
      end
      blockers.concat(membership_epoch_blockers(rollout))

      next_wave = rollout.waves.find_by(position: rollout.current_wave_position + 1)
      reviewed_wave = next_wave
      if reviewed_wave.nil? && rollout.current_wave_position.positive?
        reviewed_wave = rollout.waves.find_by(position: rollout.current_wave_position)
      end
      return blockers unless reviewed_wave

      states = readiness_for_users(reviewed_wave.participants.includes(:user).map(&:user))
      blocked = states.reject { |entry| entry.fetch(:state) == "ready" }
      if blocked.any?
        action = next_wave ? "advance" : "complete"
        blockers << "Every participant in wave #{reviewed_wave.position} must be ready before it can #{action}."
      end
      blockers
    end

    def rollback_blockers(rollout, rollback_release)
      blockers = boundary_blockers(rollout)
      blockers << "Only an active or paused rollout can roll back." unless rollout.status.in?(%w[active paused])
      blockers.concat(release_blockers(rollback_release, require_latest: false, label: "rollback"))
      if rollback_release && rollout.target_cohort_release &&
          rollback_release.release_number >= rollout.target_cohort_release.release_number
        blockers << "The rollback release must be earlier than the rollout target release."
      end
      blockers
    end

    def readiness_for_users(users)
      member_ids = Contract.participant_user_ids(cohort)
      users.sort_by(&:id).map do |user|
        {
          user_id: user.id,
          state: Contract.readiness_state(cohort: cohort, user: user, member_user_ids: member_ids)
        }
      end
    end

    def membership_epoch_blockers(rollout)
      return [] unless rollout.baseline_cohort_release_id

      memberships = cohort.cohort_memberships.where(role: "participant").index_by(&:user_id)
      changed = rollout.participants.any? do |participant|
        membership = memberships[participant.user_id]
        membership.nil? || membership.id != participant.cohort_membership_id ||
          membership.created_at != participant.membership_started_at
      end
      return [] unless changed

      [ "A participant enrollment changed after this rollout was planned. Roll back this rollout and create a new plan." ]
    end

    private

    attr_reader :cohort

    def boundary_blockers(rollout)
      return [ "The rollout does not belong to this cohort." ] unless rollout&.cohort_id == cohort.id
      return [ "The rollout does not belong to this coach workspace." ] unless rollout.coach_workspace_id == cohort.coach_workspace_id

      []
    end

    def release_blockers(release, require_latest:, label:)
      return [ "Select a sealed #{label} release." ] unless release

      blockers = []
      blockers << "The #{label} release does not belong to this cohort." unless release.cohort_id == cohort.id
      if release.coach_workspace_id != cohort.coach_workspace_id
        blockers << "The #{label} release does not belong to this coach workspace."
      end
      if require_latest && release.id != cohort.cohort_releases.order(release_number: :desc).pick(:id)
        blockers << "The rollout must target the latest sealed release."
      end
      integrity = release.integrity_report
      blockers << "The #{label} release failed its immutable evidence check." unless integrity.fetch(:valid)
      blockers << "The #{label} release is not compatible with the current runtime." unless integrity.fetch(:runtime_compatible)
      blockers
    rescue StandardError
      [ "The #{label} release could not be verified." ]
    end

    def wave_blockers(waves)
      normalized = Array(waves)
      blockers = []
      blockers << "Add at least one rollout wave." if normalized.empty?
      blockers << "A rollout can have at most #{CohortRollout::MAX_WAVES} waves." if normalized.length > CohortRollout::MAX_WAVES

      if normalized.any? { |wave| fetch(wave, :name).to_s.strip.blank? || fetch(wave, :name).to_s.strip.length > 80 }
        blockers << "Every rollout wave needs a name between 1 and 80 characters."
      end

      user_ids = normalized.flat_map { |wave| Array(fetch(wave, :user_ids)) }
      blockers << "Every rollout wave must include at least one participant." if normalized.any? { |wave| Array(fetch(wave, :user_ids)).empty? }
      blockers << "A rollout participant can appear in only one wave." if user_ids.uniq.length != user_ids.length
      blockers << "A rollout can include at most #{CohortRollout::MAX_PARTICIPANTS} participants." if user_ids.length > CohortRollout::MAX_PARTICIPANTS

      current_ids = Contract.participant_user_ids(cohort)
      normalized_ids = user_ids.filter_map { |id| integer_id(id) }.sort
      blockers << "Every rollout participant must have a valid user ID." if normalized_ids.length != user_ids.length
      unless normalized_ids == current_ids
        blockers << "The rollout waves must include every current participant exactly once."
      end
      blockers
    end

    def fetch(hash, key)
      hash[key] || hash[key.to_s]
    end

    def integer_id(value)
      value.is_a?(Integer) ? value : Integer(value, 10)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
