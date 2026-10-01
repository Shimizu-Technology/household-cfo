module HouseholdFinance
  class GoalPortfolio
    def initialize(household)
      @household = household
    end

    def as_json(*)
      active = household.goals.tracked.active.to_a
      known_targets = active.select(&:target_amount_known?)
      known_progress = active.select(&:current_amount_known?)
      {
        active_count: active.length,
        archived_count: household.goals.tracked.archived.count,
        target_total: Money.dollars(known_targets.sum(&:target_amount_cents)),
        progress_total: Money.dollars(known_progress.sum(&:current_amount_cents)),
        target_known_count: known_targets.length,
        progress_known_count: known_progress.length,
        unknown_target_goal_ids: active.reject(&:target_amount_known?).map(&:id),
        unknown_progress_goal_ids: active.reject(&:current_amount_known?).map(&:id)
      }
    end

    private

    attr_reader :household
  end
end
