class WorkosBrowserLoginAttempt < ApplicationRecord
  self.filter_attributes += [ :state_digest, :browser_digest, :encrypted_verifier, :encrypted_login_context ]
  belongs_to :workos_browser_login_operation, optional: true
end
