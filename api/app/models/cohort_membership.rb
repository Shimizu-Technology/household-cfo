class CohortMembership < ApplicationRecord
  ROLES = %w[participant coach admin].freeze

  belongs_to :cohort
  belongs_to :user

  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :cohort_id }
end
