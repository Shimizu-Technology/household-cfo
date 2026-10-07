class EnterpriseGroupMapping < ApplicationRecord
  belongs_to :enterprise_organization
  belongs_to :cohort
  validates :workos_group_id, presence: true, uniqueness: { scope: :enterprise_organization_id }, format: { with: /\Adirectory_group_[A-Za-z0-9]+\z/ }
  validate :workspace_boundary

  def as_api_json
    { id: id, workos_group_id: workos_group_id, cohort_id: cohort_id, active: active, role: "participant" }
  end

  private

  def workspace_boundary
    errors.add(:cohort, "must belong to the enterprise program") unless cohort&.coach_workspace_id == enterprise_organization&.coach_workspace_id
  end
end
