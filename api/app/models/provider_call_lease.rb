class ProviderCallLease < ApplicationRecord
  validates :provider, presence: true, length: { maximum: 64 }
  validates :slot, numericality: { only_integer: true, greater_than: 0 }
  validates :owner_token, presence: true, length: { maximum: 64 }
  validates :expires_at, presence: true
  validates :slot, uniqueness: { scope: :provider }
end
