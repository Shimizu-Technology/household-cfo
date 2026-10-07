class EnterpriseDirectoryUser < ApplicationRecord
  belongs_to :enterprise_organization
  belongs_to :enterprise_membership, optional: true
  has_many :enterprise_directory_group_memberships, dependent: :destroy
  validates :workos_directory_user_id, presence: true, uniqueness: true
  validate :membership_boundary

  private

  def membership_boundary
    if enterprise_membership && enterprise_membership.enterprise_organization_id != enterprise_organization_id
      errors.add(:enterprise_membership, "must belong to the same enterprise")
    end
  end
end
