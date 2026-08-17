module HouseholdFinance
  class PilotProgressBuilder
    SETUP_COMPLETE_THRESHOLD = 70
    MEANINGFUL_SETUP_ASSOCIATIONS = %i[income_sources expense_items accounts debts goals].freeze
    HOUSEHOLD_NOT_PROVIDED = Object.new.freeze

    def initialize(user, household: HOUSEHOLD_NOT_PROVIDED, operational_signals: nil)
      @user = user
      @household = household.equal?(HOUSEHOLD_NOT_PROVIDED) ? first_household : household
      @operational_signals = operational_signals
    end

    def call
      {
        invited: user.invited_at.present?,
        signed_in: user.last_sign_in_at.present?,
        setup_status: setup_status,
        setup_complete: setup_complete?,
        has_pending_review_work: pending_review_work?,
        last_safe_activity_at: last_safe_activity_at
      }
    end

    private

    attr_reader :user, :household, :operational_signals

    def first_household
      user.household_memberships.order(:created_at, :id).first&.household
    end

    def setup_status
      return "not_started" unless household
      return "complete" if setup_complete?
      return "started" if explicit_setup_save? || meaningful_setup_records?

      "not_started"
    end

    def setup_complete?
      return false unless household

      snapshot.fetch(:profile_completeness) >= SETUP_COMPLETE_THRESHOLD
    end

    def snapshot
      @snapshot ||= SnapshotBuilder.new(household).call
    end

    def explicit_setup_save?
      return operational_signals.fetch(:setup_saved) if operational_signals

      household.household_audit_events.where(event_type: "workspace.setup_saved").exists?
    end

    def meaningful_setup_records?
      MEANINGFUL_SETUP_ASSOCIATIONS.any? do |association_name|
        association = household.association(association_name)
        association.loaded? ? association.target.any? : household.public_send(association_name).exists?
      end
    end

    def pending_review_work?
      return false unless household
      return operational_signals.fetch(:pending_review_work) if operational_signals

      household.transaction_drafts.pending.exists? ||
        household.mia_action_drafts.pending.exists? ||
        household.financial_document_imports.pending_review.exists?
    end

    def last_safe_activity_at
      return operational_signals.fetch(:last_safe_activity_at) if operational_signals

      timestamps = [ user.last_sign_in_at, household&.updated_at ]
      return timestamps.compact.max unless household

      timestamps.concat([
        household.household_profile&.updated_at,
        maximum_timestamp(household.income_sources),
        maximum_timestamp(household.expense_items),
        maximum_timestamp(household.accounts),
        maximum_timestamp(household.debts),
        maximum_timestamp(household.goals),
        maximum_timestamp(household.financial_document_imports),
        maximum_timestamp(household.transaction_drafts),
        maximum_timestamp(household.mia_action_drafts),
        maximum_timestamp(household.chat_sessions),
        household.household_audit_events.maximum(:occurred_at),
        maximum_timestamp(household.pilot_feedback_reports)
      ])
      timestamps.compact.max
    end

    def maximum_timestamp(relation)
      relation.maximum(:updated_at)
    end
  end
end
