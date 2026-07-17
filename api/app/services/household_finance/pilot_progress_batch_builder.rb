require "set"

module HouseholdFinance
  class PilotProgressBatchBuilder
    ACTIVITY_MODELS = [
      HouseholdProfile,
      IncomeSource,
      ExpenseItem,
      Account,
      Debt,
      Goal,
      FinancialDocumentImport,
      TransactionDraft,
      MiaActionDraft,
      ChatSession,
      PilotFeedbackReport
    ].freeze

    def initialize(users)
      @users = Array(users).uniq(&:id)
    end

    def call
      return {} if users.empty?

      load_first_households
      load_operational_signals

      users.to_h do |user|
        household = households_by_user_id[user.id]
        household_id = household&.id
        progress = PilotProgressBuilder.new(
          user,
          household: household,
          operational_signals: {
            setup_saved: household_id.present? && setup_saved_household_ids.include?(household_id),
            pending_review_work: household_id.present? && pending_review_household_ids.include?(household_id),
            last_safe_activity_at: [ user.last_sign_in_at, last_activity_by_household_id[household_id] ].compact.max
          }
        ).call
        [ user.id, progress ]
      end
    end

    private

    attr_reader :users, :households_by_user_id, :setup_saved_household_ids,
      :pending_review_household_ids, :last_activity_by_household_id

    def load_first_households
      first_household_id_by_user_id = {}
      HouseholdMembership.where(user_id: user_ids)
        .order(:user_id, :created_at, :id)
        .pluck(:user_id, :household_id)
        .each do |user_id, household_id|
          first_household_id_by_user_id[user_id] ||= household_id
        end

      households_by_id = Household.where(id: first_household_id_by_user_id.values.uniq)
        .includes(
          { income_sources: :income_schedule_entries },
          :expense_items,
          :debts,
          :accounts,
          :goals
        )
        .index_by(&:id)

      @households_by_user_id = first_household_id_by_user_id.transform_values do |household_id|
        households_by_id.fetch(household_id)
      end
    end

    def load_operational_signals
      household_ids = households_by_user_id.values.map(&:id).uniq
      @setup_saved_household_ids = setup_saved_ids(household_ids)
      @pending_review_household_ids = pending_review_ids(household_ids)
      @last_activity_by_household_id = last_activity_by_household(household_ids)
    end

    def setup_saved_ids(household_ids)
      return Set.new if household_ids.empty?

      HouseholdAuditEvent.where(household_id: household_ids, event_type: "workspace.setup_saved")
        .distinct
        .pluck(:household_id)
        .to_set
    end

    def pending_review_ids(household_ids)
      return Set.new if household_ids.empty?

      [
        TransactionDraft.pending.where(household_id: household_ids).distinct.pluck(:household_id),
        MiaActionDraft.pending.where(household_id: household_ids).distinct.pluck(:household_id),
        FinancialDocumentImport.pending_review.where(household_id: household_ids).distinct.pluck(:household_id)
      ].flatten.to_set
    end

    def last_activity_by_household(household_ids)
      return {} if household_ids.empty?

      activity = households_by_user_id.values.uniq(&:id).to_h { |household| [ household.id, household.updated_at ] }
      ACTIVITY_MODELS.each do |model|
        merge_latest!(activity, model.where(household_id: household_ids).group(:household_id).maximum(:updated_at))
      end
      merge_latest!(
        activity,
        HouseholdAuditEvent.where(household_id: household_ids).group(:household_id).maximum(:occurred_at)
      )
      activity
    end

    def merge_latest!(activity, timestamps)
      timestamps.each do |household_id, timestamp|
        activity[household_id] = [ activity[household_id], timestamp ].compact.max
      end
    end

    def user_ids
      @user_ids ||= users.map(&:id)
    end
  end
end
