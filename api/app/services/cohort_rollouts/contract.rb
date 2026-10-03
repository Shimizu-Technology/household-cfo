# frozen_string_literal: true

require "digest"

module CohortRollouts
  module Contract
    STATE_SCHEMA = "cohort_rollout_state_v1"
    RUNTIME_STATE_SCHEMA = "cohort_rollout_state_v2"
    ROSTER_SCHEMA = "cohort_rollout_roster_v1"
    READINESS_SCHEMA = "cohort_rollout_readiness_v1"
    PLAN_SCHEMA = "cohort_rollout_plan_v1"

    module_function

    def canonical_json(value)
      JSON.generate(canonicalize(value))
    end

    def digest(value)
      Digest::SHA256.hexdigest(canonical_json(value))
    end

    def participant_user_ids(cohort)
      cohort.cohort_memberships.where(role: "participant").order(:user_id).pluck(:user_id)
    end

    def roster_snapshot(cohort)
      roster_snapshot_for_ids(cohort_id: cohort.id, user_ids: participant_user_ids(cohort))
    end

    def roster_snapshot_for_ids(cohort_id:, user_ids:)
      {
        "schema" => ROSTER_SCHEMA,
        "cohort_id" => cohort_id,
        "user_ids" => user_ids.sort
      }
    end

    def roster_digest(cohort)
      digest(roster_snapshot(cohort))
    end

    def roster_digest_for_ids(cohort_id:, user_ids:)
      digest(roster_snapshot_for_ids(cohort_id: cohort_id, user_ids: user_ids))
    end

    def readiness_state(cohort:, user:, member_user_ids: nil)
      member_ids = member_user_ids || participant_user_ids(cohort)
      return "removed" unless member_ids.include?(user.id)
      return "revoked" if user.revoked?
      return "ready" if user.invitation_accepted?

      "awaiting_acceptance"
    end

    def readiness_snapshot(cohort:, users: nil)
      participant_ids = participant_user_ids(cohort)
      roster_users = users || User.where(id: participant_ids).order(:id).to_a
      users_by_id = roster_users.index_by(&:id)
      entries = participant_ids.filter_map do |user_id|
        user = users_by_id[user_id]
        next unless user

        {
          "user_id" => user_id,
          "state" => readiness_state(cohort: cohort, user: user, member_user_ids: participant_ids)
        }
      end
      {
        "schema" => READINESS_SCHEMA,
        "cohort_id" => cohort.id,
        "participants" => entries
      }
    end

    def readiness_digest(cohort:, users: nil)
      digest(readiness_snapshot(cohort: cohort, users: users))
    end

    def rollout_readiness_snapshot(rollout, users: nil)
      participant_ids = rollout.participants.order(:user_id).pluck(:user_id)
      roster_users = users || User.where(id: participant_ids).order(:id).to_a
      users_by_id = roster_users.index_by(&:id)
      member_ids = participant_user_ids(rollout.cohort)
      entries = participant_ids.filter_map do |user_id|
        user = users_by_id[user_id]
        next unless user

        {
          "user_id" => user_id,
          "state" => readiness_state(cohort: rollout.cohort, user: user, member_user_ids: member_ids)
        }
      end
      {
        "schema" => READINESS_SCHEMA,
        "cohort_id" => rollout.cohort_id,
        "rollout_id" => rollout.id,
        "participants" => entries
      }
    end

    def rollout_readiness_digest(rollout, users: nil)
      digest(rollout_readiness_snapshot(rollout, users: users))
    end

    def plan_snapshot(cohort:, target_release:, waves:)
      normalized_waves = waves.each_with_index.map do |wave, index|
        {
          "position" => index + 1,
          "name" => value(wave, :name).to_s.strip,
          "user_ids" => Array(value(wave, :user_ids)).map { |id| integer_id(id) }.sort
        }
      end
      {
        "schema" => PLAN_SCHEMA,
        "cohort_id" => cohort.id,
        "coach_workspace_id" => cohort.coach_workspace_id,
        "target_release_id" => target_release.id,
        "target_release_bundle_digest" => target_release.bundle_digest,
        "waves" => normalized_waves
      }
    end

    def state_snapshot(cohort:, rollout: nil, runtime_cutover: rollout&.baseline_cohort_release_id.present?)
      payload = {
        "schema" => runtime_cutover ? RUNTIME_STATE_SCHEMA : STATE_SCHEMA,
        "cohort_id" => cohort.id,
        "coach_workspace_id" => cohort.coach_workspace_id,
        "rollout_id" => rollout&.id,
        "status" => rollout&.status,
        "current_wave_position" => rollout&.current_wave_position,
        "latest_transition_id" => nil,
        "target_release_id" => rollout&.target_cohort_release_id,
        "rollback_release_id" => rollout&.rollback_cohort_release_id,
        "participant_runtime_changed" => false
      }
      if runtime_cutover
        payload["active_release_id"] = cohort.active_cohort_release_id
        payload["baseline_release_id"] = rollout&.baseline_cohort_release_id || cohort.active_cohort_release_id
      end
      return payload unless rollout

      latest_transition = rollout.transitions.reorder(id: :desc).first
      payload.merge(
        "latest_transition_id" => latest_transition&.id
      )
    end

    def wave_readiness_snapshot(rollout, wave, users: nil, member_user_ids: nil)
      participant_ids = wave ? wave.participants.order(:user_id).pluck(:user_id) : []
      roster_users = users || User.where(id: participant_ids).order(:id).to_a
      member_ids = member_user_ids || participant_user_ids(rollout.cohort)
      {
        "schema" => READINESS_SCHEMA,
        "cohort_id" => rollout.cohort_id,
        "rollout_id" => rollout.id,
        "wave_position" => wave&.position,
        "participants" => roster_users.map do |user|
          {
            "user_id" => user.id,
            "state" => readiness_state(cohort: rollout.cohort, user: user, member_user_ids: member_ids)
          }
        end
      }
    end

    def readiness_digest_for_advance(rollout, users: nil, member_user_ids: nil)
      reviewed_wave = rollout.waves.find_by(position: rollout.current_wave_position + 1)
      if reviewed_wave.nil? && rollout.current_wave_position.positive?
        reviewed_wave = rollout.waves.find_by(position: rollout.current_wave_position)
      end
      digest(wave_readiness_snapshot(rollout, reviewed_wave, users: users, member_user_ids: member_user_ids))
    end

    def before_snapshot_for(transition:)
      rollout = transition.cohort_rollout
      if transition.event_type == "planned"
        participant_ids = rollout.participants.order(:user_id).pluck(:user_id)
        return {
          "schema" => rollout.baseline_cohort_release_id ? RUNTIME_STATE_SCHEMA : STATE_SCHEMA,
          "cohort_id" => rollout.cohort_id,
          "coach_workspace_id" => rollout.coach_workspace_id,
          "rollout_id" => nil,
          "status" => nil,
          "current_wave_position" => nil,
          "latest_transition_id" => nil,
          "target_release_id" => nil,
          "rollback_release_id" => nil,
          "latest_release_id" => rollout.target_cohort_release_id,
          "participant_roster_digest" => digest(
            roster_snapshot_for_ids(cohort_id: rollout.cohort_id, user_ids: participant_ids)
          ),
          "participant_runtime_changed" => false
        }.tap do |payload|
          if rollout.baseline_cohort_release_id
            payload["active_release_id"] = rollout.baseline_cohort_release_id
            payload["baseline_release_id"] = rollout.baseline_cohort_release_id
          end
        end
      end

      previous_transition_id = rollout.transitions.where("id < ?", transition.id).reorder(id: :desc).pick(:id)
      snapshot = transition_snapshot(
        rollout: rollout,
        status: transition.from_status,
        wave_position: transition.from_wave_position,
        latest_transition_id: previous_transition_id,
        rollback_release_id: nil
      )
      if transition.event_type.in?(%w[activated advanced completed])
        snapshot["readiness_digest"] = transition.readiness_digest
      end
      snapshot
    end

    def predicted_after_snapshot_for(transition:)
      payload = after_snapshot_for(transition: transition).merge(
        "latest_transition_id" => nil,
        "latest_transition_id_pending" => true
      )
      if transition.event_type == "planned"
        payload["rollout_id"] = nil
        payload["rollout_id_pending"] = true
      end
      payload
    end

    def after_snapshot_for(transition:)
      rollout = transition.cohort_rollout
      transition_snapshot(
        rollout: rollout,
        status: transition.to_status,
        wave_position: transition.to_wave_position,
        latest_transition_id: transition.id,
        rollback_release_id: transition.rollback_cohort_release_id || rollout.rollback_cohort_release_id,
        participant_runtime_changed: transition.participant_runtime_changed
      )
    end

    def transition_snapshot(rollout:, status:, wave_position:, latest_transition_id:, rollback_release_id:,
      participant_runtime_changed: false)
      runtime_cutover = rollout.baseline_cohort_release_id.present?
      {
        "schema" => runtime_cutover ? RUNTIME_STATE_SCHEMA : STATE_SCHEMA,
        "cohort_id" => rollout.cohort_id,
        "coach_workspace_id" => rollout.coach_workspace_id,
        "rollout_id" => rollout.id,
        "status" => status,
        "current_wave_position" => wave_position,
        "latest_transition_id" => latest_transition_id,
        "target_release_id" => rollout.target_cohort_release_id,
        "rollback_release_id" => rollback_release_id,
        "participant_runtime_changed" => participant_runtime_changed
      }.tap do |payload|
        if runtime_cutover
          payload["baseline_release_id"] = rollout.baseline_cohort_release_id
          payload["active_release_id"] = status == "completed" ? rollout.target_cohort_release_id : rollout.baseline_cohort_release_id
        end
      end
    end

    def value(hash, key)
      hash[key] || hash[key.to_s]
    end

    def integer_id(value)
      value.is_a?(Integer) ? value : Integer(value, 10)
    end

    def canonicalize(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), result| result[key.to_s] = canonicalize(item) }
          .sort.to_h
      when Array
        value.map { |item| canonicalize(item) }
      when Time, ActiveSupport::TimeWithZone
        value.utc.iso8601(6)
      when DateTime
        value.utc.iso8601(6)
      when Date
        value.iso8601
      else
        value
      end
    end
    private_class_method :canonicalize, :integer_id, :value
  end
end
