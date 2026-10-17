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
      return if cohort_id && !SavingsChallenge::ProgramMode.open?(@membership.cohort.reload)

      find
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
      enrollment = SavingsEnrollment.find_by(household: @household, user: @user, cohort: cohort)
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
