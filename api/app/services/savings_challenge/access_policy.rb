module SavingsChallenge
  class AccessPolicy
    Unavailable = Class.new(ArgumentError)

    def self.runtime_allowed?(user:, membership:)
      runtime_for(user: user, membership: membership).present?
    end

    def self.runtime_for(user:, membership:)
      runtime = Mia::ParticipantRuntimeResolver.new(user: user, cohort_membership: membership).call
      return unless runtime.membership&.id == membership.id && runtime.cohort_id == membership.cohort_id &&
        runtime.release&.tool_registry_version.to_i >= 3 && runtime.capabilities[:experience_mode] == "savings_challenge"

      runtime
    end

    def initialize(household:, user:, cohort:, enrollment: nil, lock: false)
      @household, @user, @cohort, @enrollment, @lock = household, user, cohort, enrollment, lock
    end

    def call!
      @cohort.lock! if @lock
      @user = @lock ? User.lock.find(@user.id) : User.find(@user.id)
      writable = @household.household_memberships.find_by(user_id: @user.id)&.role.in?(%w[owner partner])
      scope = @cohort.cohort_memberships
      scope = scope.lock if @lock
      membership = scope.find_by(user_id: @user.id, role: "participant")
      allowed = @user.participant? && writable && !@user.revoked? && membership && @cohort.savings_challenge_enabled &&
        !@cohort.savings_challenge_release_hold && @cohort.status.in?(%w[enrolling active completed])
      allowed &&= self.class.runtime_allowed?(user: @user, membership: membership)
      if @enrollment
        allowed &&= @enrollment.household_id == @household.id && @enrollment.user_id == @user.id &&
          @enrollment.cohort_id == @cohort.id && @enrollment.accepted_cohort_membership_id == membership&.id &&
          @enrollment.membership_started_at == membership&.created_at && @enrollment.status.in?(%w[active completed])
        allowed &&= @enrollment.accepted_cohort_release&.cohort_id == @cohort.id
      end
      raise Unavailable, "This savings challenge is not available for this participant right now" unless allowed
      membership
    end
  end
end
