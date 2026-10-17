# frozen_string_literal: true

module SavingsChallenge
  # Two separate questions about a participant's program:
  #
  # savings?  Is this membership's experience the savings challenge? That is what
  #           the participant's screens show, so it is decided from the sealed
  #           release (experience_mode + compatible tool registry), the same
  #           runtime the web reads. A cohort already switched on
  #           (savings_challenge_enabled) is always treated as a challenge so its
  #           chat and drafts can never fall back to the legacy global scope.
  # open?     Is the challenge open for financial activity right now? Enabled,
  #           not on release hold, and in a live status. AccessPolicy enforces
  #           the same rule for reads and writes.
  module ProgramMode
    OPEN_STATUSES = %w[enrolling active completed].freeze

    def self.savings?(user:, membership:, runtime: nil)
      return false unless membership

      return true if membership.cohort&.savings_challenge_enabled
      return runtime_savings?(runtime, membership) if runtime

      AccessPolicy.runtime_for(user: user, membership: membership).present?
    end

    def self.open?(cohort)
      cohort.present? && cohort.savings_challenge_enabled == true && !cohort.savings_challenge_release_hold &&
        cohort.status.in?(OPEN_STATUSES)
    end

    # "open", "paused" (switched on, then put on release hold) or "not_open"
    # (never switched on, or the cohort is in a status that cannot run it).
    def self.state(cohort)
      return "open" if open?(cohort)
      return "paused" if cohort.present? && cohort.savings_challenge_enabled == true && cohort.savings_challenge_release_hold

      "not_open"
    end

    # The cohort id that scopes chat and review drafts, or nil for an ordinary
    # program (which keeps the legacy nil-cohort history).
    def self.scope_cohort_id(user:, membership:, runtime: nil)
      savings?(user: user, membership: membership, runtime: runtime) ? membership.cohort_id : nil
    end

    def self.runtime_savings?(runtime, membership)
      runtime.membership&.id == membership.id && runtime.cohort_id == membership.cohort_id &&
        runtime.release&.tool_registry_version.to_i >= 3 && runtime.capabilities[:experience_mode] == "savings_challenge"
    end
    private_class_method :runtime_savings?
  end
end
