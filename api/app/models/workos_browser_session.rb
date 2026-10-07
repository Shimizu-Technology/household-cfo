class WorkosBrowserSession < ApplicationRecord
  self.filter_attributes += [ :cookie_digest, :encrypted_credentials ]
end
