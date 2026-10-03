# frozen_string_literal: true

module CohortRollouts
  class RuntimeMutator
    def initialize(cohort:, rollout:, actor:, actor_role_snapshot:)
      @cohort = cohort
      @rollout = rollout
      @actor = actor
      @actor_role_snapshot = actor_role_snapshot
    end

    def expose_wave!(wave:, transition:)
      ensure_baseline_active!
      memberships = participant_memberships(wave.participants.order(:user_id).pluck(:user_id))
      wave.participants.order(:user_id).each do |participant|
        membership = memberships.fetch(participant.user_id) do
          raise CohortRollouts::StateMachine::Stale, "The participant roster changed; reload before advancing."
        end
        unless participant.cohort_membership_id == membership.id && participant.membership_started_at == membership.created_at
          raise CohortRollouts::StateMachine::Stale,
            "A participant enrollment changed after this rollout was planned; create a new rollout."
        end
        CohortReleaseExposure.create!(
          coach_workspace: cohort.coach_workspace,
          cohort: cohort,
          user_id: participant.user_id,
          cohort_membership_id: membership.id,
          membership_started_at: membership.created_at,
          cohort_release: rollout.target_cohort_release,
          cohort_rollout: rollout,
          cohort_rollout_wave: wave,
          cohort_rollout_transition: transition,
          event_type: "wave",
          exposure_key: "wave:#{transition.id}:#{participant.user_id}",
          occurred_at: transition.occurred_at
        )
      end
    end

    def complete!(transition:)
      ensure_baseline_active!
      create_activation_event!(transition)
      cohort.update!(active_cohort_release: rollout.target_cohort_release)
    end

    def rollback!(transition:)
      ensure_baseline_active!
      exposed_participants = rollout.participants
        .joins(:cohort_rollout_wave)
        .where(user_id: rollout.cohort_release_exposures.where(event_type: "wave").select(:user_id))
        .includes(:cohort_rollout_wave)
        .order(:user_id)
      memberships = participant_memberships(exposed_participants.map(&:user_id))
      exposed_participants.each do |participant|
        membership = memberships[participant.user_id]
        next unless membership && participant.cohort_membership_id == membership.id &&
          participant.membership_started_at == membership.created_at

        CohortReleaseExposure.create!(
          coach_workspace: cohort.coach_workspace,
          cohort: cohort,
          user_id: participant.user_id,
          cohort_membership_id: membership.id,
          membership_started_at: membership.created_at,
          cohort_release: rollout.baseline_cohort_release,
          cohort_rollout: rollout,
          cohort_rollout_wave: participant.cohort_rollout_wave,
          cohort_rollout_transition: transition,
          event_type: "rollback",
          exposure_key: "rollback:#{transition.id}:#{participant.user_id}",
          occurred_at: transition.occurred_at
        )
      end
    end

    private

    attr_reader :cohort, :rollout, :actor, :actor_role_snapshot

    def ensure_baseline_active!
      return if cohort.active_cohort_release_id == rollout.baseline_cohort_release_id

      raise CohortRollouts::StateMachine::Stale, "The active cohort release changed; reload before continuing."
    end

    def participant_memberships(user_ids)
      cohort.cohort_memberships.where(role: "participant", user_id: user_ids).order(:user_id).lock.index_by(&:user_id)
    end

    def create_activation_event!(transition)
      key = "rollout-completed:#{transition.id}"
      CohortReleaseActivationEvent.create!(
        coach_workspace: cohort.coach_workspace,
        cohort: cohort,
        from_cohort_release: rollout.baseline_cohort_release,
        to_cohort_release: rollout.target_cohort_release,
        cohort_rollout: rollout,
        cohort_rollout_transition: transition,
        actor_user: actor,
        actor_role_snapshot: actor_role_snapshot,
        event_type: "rollout_completed",
        request_key: key,
        request_fingerprint: CohortReleases::Contract.digest(
          "schema" => "cohort_release_activation_v1",
          "cohort_id" => cohort.id,
          "from_release_id" => rollout.baseline_cohort_release_id,
          "to_release_id" => rollout.target_cohort_release_id,
          "rollout_id" => rollout.id,
          "transition_id" => transition.id,
          "actor_user_id" => actor.id,
          "actor_role_snapshot" => actor_role_snapshot,
          "request_key" => key
        ),
        occurred_at: transition.occurred_at
      )
    end
  end
end
