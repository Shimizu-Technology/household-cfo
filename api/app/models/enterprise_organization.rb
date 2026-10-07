class EnterpriseOrganization < ApplicationRecord
  belongs_to :coach_workspace
  has_many :enterprise_memberships, dependent: :restrict_with_exception
  has_many :enterprise_group_mappings, dependent: :restrict_with_exception
  has_many :enterprise_directory_users, dependent: :restrict_with_exception
  has_many :enterprise_audit_events, dependent: :restrict_with_exception
  validates :name, presence: true, length: { maximum: 160 }
  validates :workos_organization_id, presence: true, uniqueness: true, format: { with: /\Aorg_[A-Za-z0-9]+\z/ }
  validates :directory_id, uniqueness: true, allow_nil: true
  validate :immutable_boundary, on: :update

  def self.visible_to(user)
    return all if user&.admin?
    where(active: true).joins(:enterprise_memberships).where(enterprise_memberships: { user_id: user&.id, status: "active", it_admin: true, locally_revoked: false }).distinct
  end

  def as_api_json
    { id: id, name: name, coach_workspace_id: coach_workspace_id, workos_organization_id: workos_organization_id,
      active: active, require_sso: require_sso, directory_provisioning_enabled: directory_provisioning_enabled,
      setup_enabled: Enterprise::SetupPolicy.enabled?,
      directory_id: directory_id, connection_state: connection_state, directory_state: directory_state,
      last_reconciled_at: last_reconciled_at, last_sync_error: last_sync_error }
  end

  private

  def immutable_boundary
    errors.add(:base, "Enterprise identity and workspace cannot be reassigned") if will_save_change_to_workos_organization_id? || will_save_change_to_coach_workspace_id?
  end
end
