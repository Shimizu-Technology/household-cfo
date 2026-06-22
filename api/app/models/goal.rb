class Goal < ApplicationRecord
  GOAL_TYPES = %w[runway debt_payoff business_income purchase transition other].freeze

  belongs_to :household

  validates :label, presence: true
  validates :goal_type, inclusion: { in: GOAL_TYPES }
  validates :goal_type, uniqueness: { scope: :household_id }, if: :single_setup_goal_type?
  validates :target_amount_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :current_amount_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :priority, numericality: { only_integer: true }

  private

  def single_setup_goal_type?
    goal_type.in?([ "runway", "transition" ])
  end
end
