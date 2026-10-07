class EnterpriseCohortGrant < ApplicationRecord
  belongs_to :enterprise_membership
  belongs_to :cohort_membership
  validates :cohort_membership_id, uniqueness: true
  validate :participant_boundary

  private

  def participant_boundary
    valid = cohort_membership&.role == "participant" &&
      cohort_membership.user_id == enterprise_membership&.user_id &&
      cohort_membership.cohort.coach_workspace_id == enterprise_membership.enterprise_organization.coach_workspace_id
    errors.add(:cohort_membership, "must be a participant enrollment in the enterprise program") unless valid
  end
end
