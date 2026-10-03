# frozen_string_literal: true

module CohortRollouts
  class StateMachine
    Result = Struct.new(
      :rollout,
      :transition,
      :before_snapshot,
      :predicted_after_snapshot,
      :after_snapshot,
      keyword_init: true
    )

    class Error < StandardError; end
    class Stale < Error; end
    class InvalidTransition < Error; end
    class ReadOnly < Error; end
    class Ineligible < Error
      attr_reader :blockers

      def initialize(blockers)
        @blockers = blockers
        super(blockers.join(" "))
      end
    end

    def initialize(cohort:, actor:, actor_role_snapshot:)
      @cohort = cohort
      @actor = actor
      @actor_role_snapshot = actor_role_snapshot
    end

    def plan!(input)
      cohort.with_lock do
        authorize!
        ensure_cohort_mutable!
        if cohort.cohort_rollouts.where(status: CohortRollout::OPEN_STATUSES).exists?
          raise Stale, "Another rollout is already open for this cohort."
        end
        target_release = cohort.cohort_releases.find_by(id: fetch(input, :target_release_id))
        verify_equal!(fetch(input, :expected_latest_release_id), latest_release_id, "The latest sealed release changed; reload before planning.")
        locked_participant_ids = lock_current_participant_roster!
        current_roster_digest = Contract.roster_digest_for_ids(cohort_id: cohort.id, user_ids: locked_participant_ids)
        verify_equal!(fetch(input, :expected_roster_digest), current_roster_digest, "The participant roster changed; reload before planning.")
        waves = Array(fetch(input, :waves))
        blockers = eligibility.plan_blockers(target_release: target_release, waves: waves)
        raise Ineligible, blockers if blockers.any?

        User.where(id: waves.flat_map { |wave| Array(fetch(wave, :user_ids)) }.uniq.sort).order(:id).lock.load
        occurred_at = Time.current
        rollout = cohort.cohort_rollouts.create!(
          coach_workspace: cohort.coach_workspace,
          target_cohort_release: target_release,
          planned_by_user: actor,
          planned_by_role_snapshot: actor_role_snapshot,
          status: "planned",
          current_wave_position: 0,
          planned_at: occurred_at
        )
        persist_plan_roster!(rollout, waves)
        transition = create_transition!(
          rollout: rollout,
          event_type: "planned",
          from_status: nil,
          to_status: "planned",
          from_wave_position: nil,
          to_wave_position: 0,
          occurred_at: occurred_at
        )
        result_for(transition)
      end
    rescue ActiveRecord::RecordNotUnique
      raise Stale, "Another rollout is already open for this cohort."
    end

    def advance!(rollout:, input:)
      mutate!(rollout, input) do |locked_rollout, occurred_at|
        member_user_ids = lock_current_participant_roster!
        next_wave = locked_rollout.waves.find_by(position: locked_rollout.current_wave_position + 1)
        reviewed_wave = next_wave
        if reviewed_wave.nil? && locked_rollout.current_wave_position.positive?
          reviewed_wave = locked_rollout.waves.find_by(position: locked_rollout.current_wave_position)
        end
        reviewed_wave_user_ids = reviewed_wave ? reviewed_wave.participants.order(:user_id).pluck(:user_id) : []
        readiness_users = User.where(id: reviewed_wave_user_ids).order(:id).lock.to_a
        verify_equal!(
          fetch(input, :readiness_digest),
          Contract.readiness_digest_for_advance(
            locked_rollout,
            users: readiness_users,
            member_user_ids: member_user_ids
          ),
          "Participant readiness changed; reload before advancing."
        )
        blockers = eligibility.advance_blockers(locked_rollout)
        raise Ineligible, blockers if blockers.any?

        if next_wave
          event_type = locked_rollout.status == "planned" ? "activated" : "advanced"
          attributes = {
            status: "active",
            current_wave_position: next_wave.position
          }
          attributes[:activated_at] = occurred_at if locked_rollout.status == "planned"
        else
          event_type = "completed"
          attributes = { status: "completed", completed_at: occurred_at }
        end
        transition_and_update!(
          locked_rollout,
          event_type,
          attributes,
          occurred_at,
          readiness_digest: fetch(input, :readiness_digest)
        )
      end
    end

    def pause!(rollout:, input:)
      mutate!(rollout, input) do |locked_rollout, occurred_at|
        raise InvalidTransition, "Only an active rollout can be paused." unless locked_rollout.status == "active"

        transition_and_update!(locked_rollout, "paused", { status: "paused", paused_at: occurred_at }, occurred_at)
      end
    end

    def resume!(rollout:, input:)
      mutate!(rollout, input) do |locked_rollout, occurred_at|
        raise InvalidTransition, "Only a paused rollout can be resumed." unless locked_rollout.status == "paused"

        transition_and_update!(locked_rollout, "resumed", { status: "active", paused_at: nil }, occurred_at)
      end
    end

    def cancel!(rollout:, input:)
      mutate!(rollout, input, require_open_cohort: false) do |locked_rollout, occurred_at|
        raise InvalidTransition, "Only an unstarted rollout can be cancelled." unless locked_rollout.status == "planned"

        transition_and_update!(locked_rollout, "cancelled", { status: "cancelled", cancelled_at: occurred_at }, occurred_at)
      end
    end

    def rollback!(rollout:, input:)
      mutate!(rollout, input) do |locked_rollout, occurred_at|
        rollback_release = cohort.cohort_releases.find_by(id: fetch(input, :rollback_release_id))
        blockers = eligibility.rollback_blockers(locked_rollout, rollback_release)
        raise Ineligible, blockers if blockers.any?

        transition_and_update!(
          locked_rollout,
          "rolled_back",
          {
            status: "rolled_back",
            rollback_cohort_release: rollback_release,
            rolled_back_at: occurred_at
          },
          occurred_at,
          rollback_release: rollback_release
        )
      end
    end

    private

    attr_reader :cohort, :actor, :actor_role_snapshot

    def eligibility
      @eligibility ||= Eligibility.new(cohort: cohort)
    end

    def mutate!(rollout, input, require_open_cohort: true)
      cohort.with_lock do
        authorize!
        ensure_cohort_mutable! if require_open_cohort
        locked_rollout = cohort.cohort_rollouts.lock.find(rollout.id)
        verify_equal!(fetch(input, :expected_status), locked_rollout.status, "The rollout status changed; reload before continuing.")
        verify_equal!(
          fetch(input, :expected_current_wave_position),
          locked_rollout.current_wave_position,
          "The current rollout wave changed; reload before continuing."
        )
        verify_equal!(
          fetch(input, :expected_latest_transition_id),
          locked_rollout.transitions.reorder(id: :desc).pick(:id),
          "The rollout history changed; reload before continuing."
        )
        yield locked_rollout, Time.current
      end
    rescue ActiveRecord::StaleObjectError
      raise Stale, "The rollout changed; reload before continuing."
    end

    def transition_and_update!(rollout, event_type, attributes, occurred_at, rollback_release: nil, readiness_digest: nil)
      from_status = rollout.status
      from_wave_position = rollout.current_wave_position
      rollout.update!(attributes)
      transition = create_transition!(
        rollout: rollout,
        event_type: event_type,
        from_status: from_status,
        to_status: rollout.status,
        from_wave_position: from_wave_position,
        to_wave_position: rollout.current_wave_position,
        occurred_at: occurred_at,
        rollback_release: rollback_release,
        readiness_digest: readiness_digest
      )
      result_for(transition)
    end

    def create_transition!(rollout:, event_type:, from_status:, to_status:, from_wave_position:, to_wave_position:,
      occurred_at:, rollback_release: nil, readiness_digest: nil)
      rollout.transitions.create!(
        cohort: cohort,
        coach_workspace: cohort.coach_workspace,
        actor_user: actor,
        actor_role_snapshot: actor_role_snapshot,
        event_type: event_type,
        from_status: from_status,
        to_status: to_status,
        from_wave_position: from_wave_position,
        to_wave_position: to_wave_position,
        rollback_cohort_release: rollback_release,
        readiness_digest: readiness_digest,
        participant_runtime_changed: false,
        occurred_at: occurred_at
      )
    end

    def persist_plan_roster!(rollout, waves)
      timestamp = Time.current
      wave_rows = waves.each_with_index.map do |wave_input, index|
        {
          cohort_rollout_id: rollout.id,
          cohort_id: cohort.id,
          coach_workspace_id: cohort.coach_workspace_id,
          position: index + 1,
          name: fetch(wave_input, :name).to_s.squish,
          created_at: timestamp,
          updated_at: timestamp
        }
      end
      inserted = CohortRolloutWave.insert_all!(wave_rows, returning: %w[id position])
      wave_ids = inserted.rows.to_h { |id, position| [ position, id ] }
      participant_rows = waves.each_with_index.flat_map do |wave_input, index|
        Array(fetch(wave_input, :user_ids)).map(&:to_i).sort.map do |user_id|
          {
            cohort_rollout_id: rollout.id,
            cohort_rollout_wave_id: wave_ids.fetch(index + 1),
            cohort_id: cohort.id,
            coach_workspace_id: cohort.coach_workspace_id,
            user_id: user_id,
            created_at: timestamp,
            updated_at: timestamp
          }
        end
      end
      CohortRolloutParticipant.insert_all!(participant_rows)
      rollout.waves.reset
      rollout.participants.reset
    end

    def result_for(transition)
      Result.new(
        rollout: transition.cohort_rollout,
        transition: transition,
        before_snapshot: Contract.before_snapshot_for(transition: transition),
        predicted_after_snapshot: Contract.predicted_after_snapshot_for(transition: transition),
        after_snapshot: Contract.after_snapshot_for(transition: transition)
      )
    end

    def latest_release_id
      cohort.cohort_releases.order(release_number: :desc).pick(:id)
    end

    def authorize!
      persisted_actor, persisted_role = CohortReleases::Authorization.new(cohort: cohort, actor: actor).call!
      return if persisted_actor.id == actor&.id && persisted_role == actor_role_snapshot

      raise CohortReleases::Authorization::NotAuthorized,
        "Rollout authority must match the recorded workspace role"
    end

    def ensure_cohort_mutable!
      return if cohort.status.in?(Eligibility::OPEN_COHORT_STATUSES)

      raise ReadOnly, "Completed and archived cohorts are read-only."
    end

    def lock_current_participant_roster!
      cohort.cohort_memberships.where(role: "participant").order(:user_id).lock.pluck(:user_id)
    end

    def verify_equal!(expected, actual, message)
      raise Stale, message unless expected == actual
    end

    def fetch(hash, key)
      hash.key?(key) ? hash[key] : hash.fetch(key.to_s)
    end
  end
end
