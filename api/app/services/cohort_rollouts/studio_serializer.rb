# frozen_string_literal: true

module CohortRollouts
  class StudioSerializer
    HISTORY_LIMIT = 25
    ROLLBACK_SEARCH_BATCH_SIZE = 25
    RUNTIME_TRUTH = "Rollout records coordinate reviewed waves. They do not change participant access, Mia, or participant tools.".freeze

    def initialize(cohort:, actor:)
      @cohort = cohort
      @actor = actor
    end

    def call
      authorized, actor_role = rollout_authority
      rollouts = rollout_history
      total_count = cohort.cohort_rollouts.count
      releases = release_history
      release_total_count = cohort.cohort_releases.count
      current_summary = rollouts.find { |rollout| rollout.status.in?(CohortRollout::OPEN_STATUSES) }
      current = current_summary && detailed_rollout(current_summary.id)
      current_participants = current_roster_payload
      mutable = cohort.status.in?(Eligibility::OPEN_COHORT_STATUSES)
      cleanup_available = current&.status == "planned"
      plan_blockers = plan_blockers_for(current)

      {
        cohort: {
          id: cohort.id,
          name: cohort.name,
          status: cohort.status,
          participant_count: current_participants.length
        },
        runtime_truth: {
          changes_participant_runtime: false,
          participant_runtime_changed: false,
          message: RUNTIME_TRUTH
        },
        permissions: {
          view: true,
          manage: authorized && (mutable || cleanup_available),
          plan: authorized && mutable && plan_blockers.empty?,
          actor_role: actor_role,
          blockers: permission_blockers(authorized, cleanup_available: cleanup_available),
          plan_blockers: plan_blockers
        },
        current_roster: {
          digest: Contract.roster_digest_for_ids(cohort_id: cohort.id, user_ids: current_participant_ids),
          readiness_digest: current_roster_readiness_digest(current_participants),
          total_count: current_participants.length,
          counts: readiness_counts(current_participants),
          participants: current_participants
        },
        latest_release: release_payload(latest_release),
        release_history: {
          limit: HISTORY_LIMIT,
          total_count: release_total_count,
          truncated: release_total_count > releases.length
        },
        releases: releases.map { |release| release_payload(release) },
        history: {
          limit: HISTORY_LIMIT,
          total_count: total_count,
          truncated: total_count > rollouts.length
        },
        open_rollout: current && rollout_payload(current, authorized: authorized),
        rollouts: rollouts.map { |rollout| rollout_summary_payload(rollout) }
      }
    end

    def call_with_rollout(rollout)
      studio = call
      serialized = rollout_payload(detailed_rollout(rollout.id), authorized: rollout_authority.first)
      [ studio, serialized ]
    end

    private

    attr_reader :cohort, :actor

    def rollout_history
      @rollout_history ||= cohort.cohort_rollouts.order(id: :desc).limit(HISTORY_LIMIT).preload(
        :planned_by_user,
        :target_cohort_release,
        :rollback_cohort_release
      ).to_a
    end

    def detailed_rollout(id)
      @detailed_rollouts ||= {}
      @detailed_rollouts[id] ||= cohort.cohort_rollouts.where(id: id).preload(
        :planned_by_user,
        :target_cohort_release,
        :rollback_cohort_release,
        waves: { participants: :user }
      ).sole
    end

    def rollout_payload(rollout, authorized:)
      waves = rollout.waves.sort_by(&:position).map { |wave| wave_payload(rollout, wave) }
      transition_total_count = rollout.transitions.count
      transitions = rollout.transitions.reorder(id: :desc).limit(HISTORY_LIMIT)
        .preload(:actor_user, :rollback_cohort_release).to_a
      next_wave = rollout.waves.find { |wave| wave.position == rollout.current_wave_position + 1 }
      reviewed_wave_position = next_wave&.position
      reviewed_wave_position ||= rollout.current_wave_position if rollout.current_wave_position.positive?
      advance_blockers = Eligibility.new(cohort: cohort).advance_blockers(rollout)
      rollback_candidate = eligible_rollback_release(rollout) if rollout.status.in?(%w[active paused])
      rollback_blockers = rollback_blockers_for(rollout, rollback_candidate)
      mutable = cohort.status.in?(Eligibility::OPEN_COHORT_STATUSES)

      {
        id: rollout.id,
        status: rollout.status,
        target_release: release_payload(rollout.target_cohort_release),
        rollback_release: release_payload(rollout.rollback_cohort_release),
        rollback_candidate: release_payload(rollback_candidate),
        planned_by: actor_payload(rollout.planned_by_user, rollout.planned_by_role_snapshot),
        planned_at: rollout.planned_at,
        activated_at: rollout.activated_at,
        paused_at: rollout.paused_at,
        completed_at: rollout.completed_at,
        cancelled_at: rollout.cancelled_at,
        rolled_back_at: rollout.rolled_back_at,
        current_wave_position: rollout.current_wave_position,
        wave_count: waves.length,
        participant_count: waves.sum { |wave| wave.fetch(:participant_count) },
        latest_transition_id: transitions.first&.id,
        readiness_digest: rollout_readiness_digest(rollout, waves),
        next_wave_readiness_digest: wave_readiness_digest(rollout, waves, reviewed_wave_position),
        next_wave_position: next_wave&.position,
        permissions: {
          advance: authorized && mutable && advance_blockers.empty?,
          pause: authorized && mutable && rollout.status == "active",
          resume: authorized && mutable && rollout.status == "paused",
          cancel: authorized && rollout.status == "planned",
          rollback: authorized && mutable && rollback_blockers.empty?,
          advance_blockers: advance_blockers,
          rollback_blockers: rollback_blockers
        },
        waves: waves,
        transition_history: {
          limit: HISTORY_LIMIT,
          total_count: transition_total_count,
          truncated: transition_total_count > transitions.length
        },
        transitions: transitions.map { |transition| transition_payload(transition) },
        participant_runtime_changed: false
      }
    end

    def rollout_summary_payload(rollout)
      transition_total_count = rollout_transition_counts.fetch(rollout.id, 0)
      {
        id: rollout.id,
        status: rollout.status,
        target_release: release_payload(rollout.target_cohort_release),
        rollback_release: release_payload(rollout.rollback_cohort_release),
        planned_by: actor_payload(rollout.planned_by_user, rollout.planned_by_role_snapshot),
        planned_at: rollout.planned_at,
        activated_at: rollout.activated_at,
        paused_at: rollout.paused_at,
        completed_at: rollout.completed_at,
        cancelled_at: rollout.cancelled_at,
        rolled_back_at: rollout.rolled_back_at,
        current_wave_position: rollout.current_wave_position,
        wave_count: rollout_wave_counts.fetch(rollout.id, 0),
        participant_count: rollout_participant_counts.fetch(rollout.id, 0),
        latest_transition_id: rollout_latest_transition_ids[rollout.id],
        transition_history: {
          limit: HISTORY_LIMIT,
          total_count: transition_total_count,
          truncated: transition_total_count > HISTORY_LIMIT
        },
        participant_runtime_changed: false
      }
    end

    def wave_payload(rollout, wave)
      member_ids = current_participant_ids
      participants = wave.participants.sort_by(&:user_id).map do |participant|
        user = participant.user
        {
          user_id: user.id,
          full_name: participant_display_name(user),
          readiness: Contract.readiness_state(cohort: cohort, user: user, member_user_ids: member_ids)
        }
      end
      {
        id: wave.id,
        position: wave.position,
        name: wave.name,
        active: rollout.status.in?(%w[active paused]) && rollout.current_wave_position == wave.position,
        completed: rollout.current_wave_position > wave.position || rollout.status == "completed",
        participant_count: participants.length,
        counts: readiness_counts(participants),
        participants: participants
      }
    end

    def current_roster_payload
      users = current_participant_users
      member_ids = users.map(&:id)
      users.map do |user|
        {
          user_id: user.id,
          full_name: participant_display_name(user),
          readiness: Contract.readiness_state(cohort: cohort, user: user, member_user_ids: member_ids)
        }
      end
    end

    def readiness_counts(participants)
      counts = %w[ready awaiting_acceptance revoked removed].index_with { 0 }
      participants.each { |participant| counts[participant.fetch(:readiness)] += 1 }
      counts
    end

    def transition_payload(transition)
      {
        id: transition.id,
        event_type: transition.event_type,
        from_status: transition.from_status,
        to_status: transition.to_status,
        from_wave_position: transition.from_wave_position,
        to_wave_position: transition.to_wave_position,
        rollback_release_id: transition.rollback_cohort_release_id,
        readiness_digest: transition.readiness_digest,
        actor: actor_payload(transition.actor_user, transition.actor_role_snapshot),
        occurred_at: transition.occurred_at,
        participant_runtime_changed: false
      }
    end

    def release_payload(release)
      return nil unless release

      @release_payloads ||= {}
      return @release_payloads.fetch(release.id) if @release_payloads.key?(release.id)

      integrity = release_integrity(release)
      @release_payloads[release.id] = {
        id: release.id,
        release_number: release.release_number,
        bundle_digest: release.bundle_digest,
        integrity_valid: integrity.fetch(:valid),
        runtime_compatible: integrity.fetch(:runtime_compatible),
        released_at: release.released_at
      }
    end

    def rollback_blockers_for(rollout, rollback_candidate)
      return [ "Only an active or paused rollout can roll back." ] unless rollout.status.in?(%w[active paused])
      return [] if rollback_candidate

      if rollout.target_cohort_release.release_number <= 1 ||
          cohort.cohort_releases.where("release_number < ?", rollout.target_cohort_release.release_number).none?
        [ "No earlier sealed release is available for rollback." ]
      else
        [ "No earlier release passed integrity and runtime compatibility checks." ]
      end
    end

    def eligible_rollback_release(rollout)
      @eligible_rollback_releases ||= {}
      return @eligible_rollback_releases[rollout.id] if @eligible_rollback_releases.key?(rollout.id)

      cursor = rollout.target_cohort_release.release_number
      loop do
        releases = cohort.cohort_releases
          .where("release_number < ?", cursor)
          .order(release_number: :desc)
          .limit(ROLLBACK_SEARCH_BATCH_SIZE)
          .preload(*CohortReleases::StudioSerializer::RELEASE_HISTORY_PRELOADS)
          .to_a
        break if releases.empty?

        candidate = releases.find do |release|
          integrity = release_integrity(release)
          integrity.fetch(:valid) && integrity.fetch(:runtime_compatible)
        end
        return @eligible_rollback_releases[rollout.id] = candidate if candidate

        break if releases.length < ROLLBACK_SEARCH_BATCH_SIZE

        cursor = releases.last.release_number
      end

      @eligible_rollback_releases[rollout.id] = nil
    end

    def release_integrity(release)
      @release_integrities ||= {}
      @release_integrities[release.id] ||= release.integrity_report
    rescue StandardError
      @release_integrities[release.id] = { valid: false, runtime_compatible: false }
    end

    def actor_payload(user, role)
      return nil unless user

      { id: user.id, full_name: workspace_member_display_name(user), role: role }
    end

    def participant_display_name(user)
      name = [ user.first_name, user.last_name ].compact_blank.join(" ").squish
      name.presence || "Participant #{user.id}"
    end

    def workspace_member_display_name(user)
      name = [ user.first_name, user.last_name ].compact_blank.join(" ").squish
      name.presence || "Workspace member #{user.id}"
    end

    def latest_release
      return @latest_release if defined?(@latest_release)

      @latest_release = cohort.cohort_releases.order(release_number: :desc).first
    end

    def release_history
      cohort.cohort_releases.order(release_number: :desc).limit(HISTORY_LIMIT).to_a
    end

    def rollout_authority
      @rollout_authority ||= CohortReleases::Authorization.new(cohort: cohort, actor: actor).call!
    rescue CohortReleases::Authorization::NotAuthorized
      @rollout_authority = [ false, workspace_role ]
    end

    def workspace_role
      return "platform_admin" if actor&.admin?

      cohort.coach_workspace.membership_for(actor)&.role
    end

    def current_participant_users
      @current_participant_users ||= cohort.cohort_memberships.where(role: "participant").includes(:user)
        .map(&:user).sort_by(&:id)
    end

    def current_participant_ids
      @current_participant_ids ||= current_participant_users.map(&:id)
    end

    def current_roster_readiness_digest(participants)
      Contract.digest(
        "schema" => Contract::READINESS_SCHEMA,
        "cohort_id" => cohort.id,
        "participants" => participants.map do |participant|
          {
            "user_id" => participant.fetch(:user_id),
            "state" => participant.fetch(:readiness)
          }
        end
      )
    end

    def rollout_readiness_digest(rollout, waves)
      participants = waves.flat_map { |wave| wave.fetch(:participants) }.sort_by { |item| item.fetch(:user_id) }
      Contract.digest(
        "schema" => Contract::READINESS_SCHEMA,
        "cohort_id" => cohort.id,
        "rollout_id" => rollout.id,
        "participants" => readiness_entries(participants)
      )
    end

    def wave_readiness_digest(rollout, waves, position)
      wave = waves.find { |item| item.fetch(:position) == position }
      Contract.digest(
        "schema" => Contract::READINESS_SCHEMA,
        "cohort_id" => cohort.id,
        "rollout_id" => rollout.id,
        "wave_position" => position,
        "participants" => readiness_entries(wave ? wave.fetch(:participants) : [])
      )
    end

    def readiness_entries(participants)
      participants.map do |participant|
        {
          "user_id" => participant.fetch(:user_id),
          "state" => participant.fetch(:readiness)
        }
      end
    end

    def rollout_ids
      @rollout_ids ||= rollout_history.map(&:id)
    end

    def rollout_wave_counts
      @rollout_wave_counts ||= CohortRolloutWave.where(cohort_rollout_id: rollout_ids)
        .group(:cohort_rollout_id).count
    end

    def rollout_participant_counts
      @rollout_participant_counts ||= CohortRolloutParticipant.where(cohort_rollout_id: rollout_ids)
        .group(:cohort_rollout_id).count
    end

    def rollout_transition_counts
      @rollout_transition_counts ||= CohortRolloutTransition.where(cohort_rollout_id: rollout_ids)
        .group(:cohort_rollout_id).count
    end

    def rollout_latest_transition_ids
      @rollout_latest_transition_ids ||= CohortRolloutTransition.where(cohort_rollout_id: rollout_ids)
        .group(:cohort_rollout_id).maximum(:id)
    end

    def permission_blockers(authorized, cleanup_available:)
      blockers = []
      blockers << "Only a workspace owner or reviewer can manage rollout records." unless authorized
      unless cohort.status.in?(Eligibility::OPEN_COHORT_STATUSES)
        message = if cleanup_available
          "This cohort is read-only except for cancelling its unstarted rollout."
        else
          "Completed and archived cohorts are read-only."
        end
        blockers << message
      end
      blockers
    end

    def plan_blockers_for(current)
      blockers = []
      blockers << "Another rollout is already open for this cohort." if current
      release = latest_release
      if release.nil?
        blockers << "Seal a cohort release before planning a rollout."
      else
        integrity = release_integrity(release)
        blockers << "The latest sealed release failed its immutable evidence check." unless integrity.fetch(:valid)
        unless integrity.fetch(:runtime_compatible)
          blockers << "The latest sealed release is not compatible with the current runtime."
        end
      end
      blockers << "Add at least one participant before planning a rollout." if current_participant_ids.empty?
      blockers
    end
  end
end
