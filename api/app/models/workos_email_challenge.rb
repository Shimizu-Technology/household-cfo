class WorkosEmailChallenge < ApplicationRecord
  self.filter_attributes += [ :challenge_digest, :browser_digest, :encrypted_context ]
end
