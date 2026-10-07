class WorkosBrowserLoginAttempt < ApplicationRecord
  self.filter_attributes += [ :state_digest, :browser_digest, :encrypted_verifier ]
end
