class EnterpriseMembership < ApplicationRecord
  belongs_to :enterprise_organization
  belongs_to :user, optional: true
  has_many :enterprise_directory_users, dependent: :restrict_with_exception
  has_many :enterprise_cohort_grants, dependent: :restrict_with_exception
  validates :workos_user_id, presence: true, uniqueness: { scope: :enterprise_organization_id }, format: { with: /\Auser_[A-Za-z0-9]+\z/ }
  validates :user_id, uniqueness: { scope: :enterprise_organization_id }, allow_nil: true
  validates :status, inclusion: { in: %w[pending active inactive] }

  def active_access?
    status == "active" && !locally_revoked? && enterprise_organization.active?
  end

  def as_api_json
    { id: id, user_id: user_id, workos_user_id: workos_user_id, status: status, it_admin: it_admin,
      locally_revoked: locally_revoked, email: user&.email, full_name: user&.full_name }
  end
end
