class EnterpriseSyncCursor < ApplicationRecord
  validates :name, presence: true, uniqueness: true
end
