class HouseholdMembership < ApplicationRecord
  ROLES = %w[owner partner coach_viewer].freeze
  HOME_VIEWS = CohortExperience::MethodSettings::CHOICES.fetch("home_view")

  belongs_to :household
  belongs_to :user

  validates :role, inclusion: { in: ROLES }
  validates :home_view, inclusion: { in: HOME_VIEWS }, allow_nil: true
  validates :user_id, uniqueness: { scope: :household_id }
  validates :user_id,
    uniqueness: { conditions: -> { where(role: "owner") }, message: "already owns a household" },
    if: -> { role == "owner" }
end
