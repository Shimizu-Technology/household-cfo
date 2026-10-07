require "test_helper"
require_relative "../support/workos_auth_test_support"

class WorkosIdentityMappingTest < ActiveSupport::TestCase
  include WorkosAuthTestSupport

  test "mapping is dry run by default and idempotent when applied" do
    user = User.create!(clerk_id: "clerk_mapping", email: "workos@example.com", role: "admin")
    with_workos do
      with_workos_http do
        args = { user_id: user.id, subject: "user_test", expected_clerk_id: user.clerk_id }
        assert_no_difference("AuthenticationIdentity.count") { WorkosIdentityMapping.bind!(**args) }
        assert_difference("AuthenticationIdentity.count", 1) { WorkosIdentityMapping.bind!(**args, dry_run: false) }
        assert_no_difference("AuthenticationIdentity.count") { WorkosIdentityMapping.bind!(**args, dry_run: false) }
        assert_equal "admin", user.reload.role
        assert_equal "clerk_mapping", user.clerk_id
      end
    end
  end

  test "mapping rejects stale local identity email mismatch revocation and collisions" do
    user = User.create!(clerk_id: "clerk_mapping", email: "workos@example.com")
    other = User.create!(clerk_id: "clerk_other", email: "other@example.com")
    with_workos do
      with_workos_http do
        args = { user_id: user.id, subject: "user_test", expected_clerk_id: user.clerk_id, dry_run: false }
        assert_raises(WorkosIdentityMapping::Conflict) { WorkosIdentityMapping.bind!(**args.merge(expected_clerk_id: "stale")) }
        assert_raises(WorkosIdentityMapping::Conflict) { WorkosIdentityMapping.bind!(**args.merge(user_id: other.id, expected_clerk_id: other.clerk_id)) }
        user.update!(invitation_status: "revoked")
        assert_raises(WorkosIdentityMapping::Conflict) { WorkosIdentityMapping.bind!(**args) }
        user.update!(invitation_status: "accepted")
        other.authentication_identities.create!(provider: "workos", issuer: WorkosAuth.issuer, subject: "user_test")
        assert_raises(WorkosIdentityMapping::Conflict) { WorkosIdentityMapping.bind!(**args) }
      end
    end
  end

  test "database identity uniqueness rejects external and local account collisions" do
    user = User.create!(clerk_id: "clerk_mapping", email: "workos@example.com")
    other = User.create!(clerk_id: "clerk_other", email: "other@example.com")
    user.authentication_identities.create!(provider: "workos", issuer: "https://api.workos.com", subject: "user_test")
    assert_raises(ActiveRecord::RecordInvalid) do
      other.authentication_identities.create!(provider: "workos", issuer: "https://api.workos.com", subject: "user_test")
    end
    assert_raises(ActiveRecord::RecordInvalid) do
      user.authentication_identities.create!(provider: "workos", issuer: "https://api.workos.com", subject: "user_other")
    end
    assert_raises(ActiveRecord::RecordNotUnique) do
      AuthenticationIdentity.transaction(requires_new: true) do
        AuthenticationIdentity.insert_all!([ { user_id: other.id, provider: "workos", issuer: "https://api.workos.com", subject: "user_test" } ])
      end
    end
  end
end
