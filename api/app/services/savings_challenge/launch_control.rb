# frozen_string_literal: true

require "digest"
require "json"

module SavingsChallenge
  # Audited, platform-admin-only control that opens or pauses a cohort's savings
  # challenge. It is the only supported way to change the cohort's
  # savings_challenge_enabled / savings_challenge_release_hold flags; participant
  # access itself is still decided by SavingsChallenge::AccessPolicy.
  class LaunchControl
    class NotAuthorized < StandardError; end
    class Invalid < StandardError; end
    class Refused < StandardError; end
    class Conflict < StandardError; end

    Result = Data.define(:event, :replayed) # event is nil for a no-op pause
    OPEN_STATUSES = %w[enrolling active].freeze

    def initialize(cohort:, actor: nil)
      @cohort = cohort
      @actor = actor
    end

    # Plain description of where the challenge stands for this cohort.
    def status
      blockers = open_blockers
      state = state_for(cohort, blockers)
      {
        state: state,
        label: LABELS.fetch(state),
        enabled: cohort.savings_challenge_enabled,
        on_hold: cohort.savings_challenge_release_hold,
        capacity: cohort.savings_challenge_capacity,
        participant_count: cohort.cohort_memberships.where(role: "participant").count,
        can_open: blockers.empty? && state != "open",
        can_pause: state == "open",
        blockers: blockers,
        participants_can_join: state == "open" && blockers.empty?,
        recent_events: cohort.cohort_challenge_access_events.includes(:actor_user).order(occurred_at: :desc, id: :desc).limit(5).map { |event| serialize_event(event) }
      }
    end

    def open!(reason:, request_key:, expected_state:)
      change!("open", reason: reason, request_key: request_key, expected_state: expected_state)
    end

    def pause!(reason:, request_key:)
      change!("pause", reason: reason, request_key: request_key, expected_state: nil)
    end

    private

    LABELS = {
      "not_set_up" => "Not set up",
      "ready" => "Ready to open",
      "open" => "Open",
      "paused" => "Paused"
    }.freeze

    attr_reader :cohort, :actor

    def change!(action, reason:, request_key:, expected_state:)
      key = request_key.to_s.strip
      raise Invalid, "Idempotency-Key must be between 1 and 255 characters" unless key.length.between?(1, 255)
      text = reason.to_s.squish
      raise Invalid, "Give a short reason (at least 5 characters, up to 500)." unless text.length.between?(5, 500)

      cohort.with_lock do
        locked_actor = User.lock.find_by(id: actor&.id)
        unless locked_actor&.admin? && !locked_actor.revoked?
          raise NotAuthorized, "Only a platform administrator can open or pause the savings challenge."
        end

        fingerprint = Digest::SHA256.hexdigest(JSON.generate(
          "schema" => "cohort_challenge_access_request_v1", "cohort_id" => cohort.id, "action" => action,
          "actor_user_id" => locked_actor.id, "reason" => text, "expected_state" => expected_state.to_s, "request_key" => key
        ))
        existing = cohort.cohort_challenge_access_events.find_by(request_key: key)
        if existing
          raise Conflict, "That request was already used for a different change. Reload and try again." unless existing.request_fingerprint == fingerprint

          return Result.new(event: existing, replayed: true)
        end

        blockers = open_blockers
        from_state = state_for(cohort, blockers)
        if action == "open"
          raise Conflict, "The challenge changed since you opened this page. Reload and try again." unless expected_state.to_s == from_state
          raise Conflict, "The challenge is already open." if from_state == "open"
          raise Refused, blockers.to_sentence if blockers.any?
        end

        # Pausing something that is not open changes nothing, so it records nothing:
        # it succeeds as a no-op (the hold is already on or the challenge never opened).
        if action == "pause" && from_state != "open"
          cohort.update!(savings_challenge_release_hold: true) unless cohort.savings_challenge_release_hold
          return Result.new(event: nil, replayed: false)
        end

        before = { enabled: cohort.savings_challenge_enabled, hold: cohort.savings_challenge_release_hold }
        if action == "open"
          cohort.update!(savings_challenge_enabled: true, savings_challenge_release_hold: false)
        else
          cohort.update!(savings_challenge_release_hold: true)
        end
        event = cohort.cohort_challenge_access_events.create!(
          coach_workspace_id: cohort.coach_workspace_id, actor_user: locked_actor, cohort_release_id: cohort.active_cohort_release_id,
          action: action, actor_role_snapshot: "platform_admin", reason: text,
          from_state: from_state, to_state: state_for(cohort, blockers),
          enabled_before: before[:enabled], hold_before: before[:hold],
          enabled_after: cohort.savings_challenge_enabled, hold_after: cohort.savings_challenge_release_hold,
          request_key: key, request_fingerprint: fingerprint, occurred_at: Time.current
        )
        Result.new(event: event, replayed: false)
      end
    end

    def state_for(record, blockers)
      return "open" if record.savings_challenge_enabled && !record.savings_challenge_release_hold
      return "paused" if record.savings_challenge_enabled && record.savings_challenge_release_hold
      blockers.empty? ? "ready" : "not_set_up"
    end

    # Plain reasons the challenge cannot be opened right now. Sharing
    # AccessPolicy's release check means we never open a cohort that
    # participants would then be refused.
    def open_blockers
      blockers = []
      release = cohort.active_cohort_release
      if release.nil?
        blockers << "Seal and launch a release first."
      elsif !SavingsChallenge::AccessPolicy.release_supports_challenge?(release)
        blockers << "The launched release is not the Savings Challenge experience. Choose Savings Challenge in Participant tools, publish, seal, and launch again."
      end
      blockers << "Set the cohort status to Enrolling or Active first." unless cohort.status.in?(OPEN_STATUSES)
      blockers
    end

    def serialize_event(event)
      {
        id: event.id, action: event.action, from_state: event.from_state, to_state: event.to_state,
        reason: event.reason, occurred_at: event.occurred_at, actor_name: event.actor_user.full_name.presence || event.actor_user.email
      }
    end
  end
end
