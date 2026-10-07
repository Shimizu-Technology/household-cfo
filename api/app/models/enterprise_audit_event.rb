class EnterpriseAuditEvent < ApplicationRecord
  belongs_to :enterprise_organization
  belongs_to :actor_user, class_name: "User", optional: true
  validates :action, presence: true
end
