class HouseholdMembership < ApplicationRecord
  ROLES = %w[owner partner coach_viewer].freeze

  belongs_to :household
  belongs_to :user

  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :household_id }
  validates :user_id,
    uniqueness: { conditions: -> { where(role: "owner") }, message: "already owns a household" },
    if: -> { role == "owner" }
end
