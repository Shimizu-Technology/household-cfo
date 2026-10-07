class EnterpriseDirectoryGroupMembership < ApplicationRecord
  belongs_to :enterprise_directory_user
  validates :workos_group_id, presence: true, uniqueness: { scope: :enterprise_directory_user_id }
end
