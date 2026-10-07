class WorkosBrowserLoginOperation < ApplicationRecord
  self.filter_attributes += [ :state_digest, :browser_digest, :completed_cookie_digest ]
  has_many :login_attempts, class_name: "WorkosBrowserLoginAttempt", dependent: :delete_all
end
