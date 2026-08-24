require "test_helper"

class ProviderCallLeaseTest < ActiveSupport::TestCase
  test "provider slots are unique and bounded to positive integers" do
    lease = ProviderCallLease.create!(
      provider: "test-provider",
      slot: 1,
      owner_token: SecureRandom.uuid,
      expires_at: 30.seconds.from_now
    )
    duplicate = ProviderCallLease.new(
      provider: lease.provider,
      slot: lease.slot,
      owner_token: SecureRandom.uuid,
      expires_at: 30.seconds.from_now
    )
    invalid = ProviderCallLease.new(
      provider: "test-provider",
      slot: 0,
      owner_token: SecureRandom.uuid,
      expires_at: 30.seconds.from_now
    )

    refute duplicate.valid?
    refute invalid.valid?
  end
end
