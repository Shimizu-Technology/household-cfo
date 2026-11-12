# frozen_string_literal: true

module Mia
  # Conversation state, requests and evidence share the same authorized program
  # boundary. A legacy household session is never a fallback for a challenge.
  class ChatSessionScope
    def initialize(household:, user:, membership:, runtime: nil)
      @household, @user, @membership, @runtime = household, user, membership, runtime
    end

    def find
      authorize!
      relation.first
    end

    # For showing history: a challenge that is not open yet (or is paused) has
    # nothing to show, and reading it must not raise a raw error at the
    # participant. Writes, replay and clearing still go through authorize!.
    def find_for_display
      @membership.cohort.reload if cohort_id
      return if cohort_id && !SavingsChallenge::ProgramMode.available?(user: @user, membership: @membership, runtime: @runtime)

      find
    end

    # Safety-only read: program availability must not end an existing episode.
    # The selected actor, household and cohort still define the exact scope.
    # Never create a session or write challenge data through this route.
    def care_while_closed
      return unless @membership && @membership.user_id == @user.id
      return unless @membership.role.in?(%w[participant preview])
      session = relation.first
      HouseholdFinance::ParticipantCareState.new(session).active if session
    end

    def find_or_create!
      @household.with_lock do
        authorize!
        relation.first || relation.create!(title: "Ask Mia")
      end
    end

    def authorize!
      return unless cohort_id

      cohort = Cohort.find(cohort_id)
      enrollment = SavingsEnrollment.in_use.find_by(household: @household, user: @user, cohort: cohort)
      membership = SavingsChallenge::AccessPolicy.new(household: @household, user: @user, cohort: cohort, enrollment: enrollment).call!
      fresh = SavingsChallenge::AccessPolicy.runtime_for(user: @user, membership: membership)
      unless membership.id == @membership.id && (!@runtime || fresh&.release_id == @runtime.release_id)
        raise SavingsChallenge::AccessPolicy::Unavailable, "This savings challenge conversation is no longer available"
      end
    end

    def cohort_id
      @cohort_id ||= SavingsChallenge::ProgramMode.scope_cohort_id(user: @user, membership: @membership, runtime: @runtime)
    end

    private

    def relation
      @household.chat_sessions.where(user: @user, cohort_id: cohort_id)
    end
  end
end
