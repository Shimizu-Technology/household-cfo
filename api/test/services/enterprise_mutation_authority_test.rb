require "test_helper"
require_relative "../support/workos_auth_test_support"

class EnterpriseMutationAuthorityTest < ActiveSupport::TestCase
  include WorkosAuthTestSupport

  setup do
    key = SecureRandom.hex(6)
    @admin = User.create!(clerk_id: "admin_#{key}", email: "admin_#{key}@local.test", role: "admin")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(@admin)
    @organization = EnterpriseOrganization.create!(name: "Bank", workos_organization_id: "org_bank", coach_workspace: workspace)
  end

  test "stale persisted demoted revoked and pending administrators cannot mutate" do
    [ { role: "participant" }, { invitation_status: "revoked" }, { invitation_status: "pending" } ].each do |changes|
      @admin.update!(role: "admin", invitation_status: "accepted")
      stale = User.find(@admin.id)
      @admin.update!(changes)
      assert_raises(EnterpriseAccess::Denied) do
        Enterprise::MutationAuthority.call(actor: stale, organization: @organization) { raise "Must not mutate" }
      end
    end
  end

  test "enterprise bound global administrator cannot use Clerk rollback or another organization" do
    @organization.enterprise_memberships.create!(user: @admin, workos_user_id: "user_admin", status: "active", it_admin: true)
    assert_raises(EnterpriseAccess::Denied) do
      Enterprise::MutationAuthority.call(actor: @admin, organization: @organization, claims: { "sub" => "clerk_admin" }, provider: "clerk") { raise "Must not mutate" }
    end
  end

  test "portal discards issued link when administrator is demoted during provider HTTP" do
    previous = ENV["WORKOS_ADMIN_PORTAL_RETURN_URLS"]
    ENV["WORKOS_ADMIN_PORTAL_RETURN_URLS"] = "https://app.bank.test/?enterprise=1"
    actor = @admin
    client = Object.new
    client.define_singleton_method(:portal) do |**_options|
      User.where(id: actor.id).update_all(role: "participant")
      "https://setup.workos.com?token=test"
    end
    assert_no_difference("EnterpriseAuditEvent.count") do
      assert_raises(EnterpriseAccess::Denied) do
        Enterprise::Portal.call(organization: @organization, user: @admin, intent: "sso", return_url: ENV["WORKOS_ADMIN_PORTAL_RETURN_URLS"], client: client)
      end
    end
  ensure
    ENV["WORKOS_ADMIN_PORTAL_RETURN_URLS"] = previous
  end

  test "portal discards issued link when IT access is locally revoked during provider HTTP" do
    previous = ENV["WORKOS_ADMIN_PORTAL_RETURN_URLS"]
    ENV["WORKOS_ADMIN_PORTAL_RETURN_URLS"] = "https://app.bank.test/?enterprise=1"
    it = User.create!(clerk_id: "it_#{SecureRandom.hex(6)}", email: "#{SecureRandom.hex(6)}@local.test")
    membership = @organization.enterprise_memberships.create!(user: it, workos_user_id: "user_it", status: "active", it_admin: true)
    client = Object.new
    client.define_singleton_method(:memberships) { |organization_id:, user_id:| [ { "organization_id" => organization_id, "user_id" => user_id, "status" => "active" } ] }
    client.define_singleton_method(:sessions) { |subject| [ { "id" => "session_it", "user_id" => subject, "organization_id" => "org_bank", "status" => "active", "auth_method" => "sso" } ] }
    client.define_singleton_method(:portal) do |**_options|
      membership.update!(locally_revoked: true)
      "https://setup.workos.com?token=test"
    end
    assert_no_difference("EnterpriseAuditEvent.count") do
      assert_raises(EnterpriseAccess::Denied) do
        Enterprise::Portal.call(organization: @organization, user: it, intent: "sso", return_url: ENV["WORKOS_ADMIN_PORTAL_RETURN_URLS"], client: client,
          claims: { "org_id" => "org_bank", "sub" => "user_it", "sid" => "session_it" }, provider: "workos")
      end
    end
  ensure
    ENV["WORKOS_ADMIN_PORTAL_RETURN_URLS"] = previous
  end

  test "newer authoritative absence prevents old first seen directory users and groups" do
    participant = User.create!(clerk_id: "participant_#{SecureRandom.hex(6)}", email: "#{SecureRandom.hex(6)}@local.test")
    membership = @organization.enterprise_memberships.create!(user: participant, workos_user_id: "user_participant", status: "active")
    @organization.update!(directory_id: "directory_bank", last_reconciled_at: Time.current)
    snapshot = [ { data: { "id" => "directory_user_new", "directory_id" => "directory_bank", "organization_id" => "org_bank", "email" => "person@bank.test", "state" => "active" }, group_ids: [ "directory_group_new" ] } ]
    assert_no_difference([ "EnterpriseDirectoryUser.count", "EnterpriseDirectoryGroupMembership.count", "CohortMembership.count" ]) do
      assert_raises(Enterprise::Client::Unavailable) do
        @organization.with_lock { Enterprise::Provisioner.apply_directory_snapshot!(@organization, membership, snapshot, observed_at: 1.minute.ago) }
      end
    end
    @organization.update!(last_reconciled_at: nil)
    membership.update!(provider_updated_at: Time.current)
    assert_no_difference("EnterpriseDirectoryUser.count") do
      assert_raises(Enterprise::Client::Unavailable) do
        @organization.with_lock { Enterprise::Provisioner.apply_directory_snapshot!(@organization, membership, snapshot, observed_at: 1.minute.ago) }
      end
    end
  end
end
