require_relative "enterprise_provisioning_test"

class EnterpriseAdmissionTest < ActiveSupport::TestCase
  setup do
    @admin = User.create!(clerk_id: "admin_#{SecureRandom.hex(6)}", email: "#{SecureRandom.hex(6)}@local.test", role: "admin")
    @workspace = CoachWorkspaces::Provisioner.ensure_for!(@admin)
    @cohort = Cohort.create!(name: "Admission", coach_workspace: @workspace, created_by_user: @admin, status: "active")
    @organization = EnterpriseOrganization.create!(name: "Bank", coach_workspace: @workspace, workos_organization_id: "org_bank", directory_id: "directory_bank", directory_provisioning_enabled: true)
    @organization.enterprise_group_mappings.create!(workos_group_id: "directory_group_participants", cohort: @cohort)
    @client = EnterpriseProvisioningTest::FakeClient.new
    @client.provider_memberships = [ { "id" => "om_new", "user_id" => "user_new", "organization_id" => "org_bank", "status" => "active", "updated_at" => "2026-10-07T20:00:00Z", "role" => { "slug" => "admin" } } ]
    @client.users = [ { "id" => "directory_user_new", "directory_id" => "directory_bank", "organization_id" => "org_bank", "email" => "user_new@bank.test", "state" => "active", "updated_at" => "2026-10-07T20:00:00Z" } ]
    @client.groups = [ { "id" => "directory_group_participants", "directory_id" => "directory_bank", "organization_id" => "org_bank" } ]
    @client.session_rows = [ { "id" => "session_new", "user_id" => "user_new", "organization_id" => "org_bank", "status" => "active", "auth_method" => "sso" } ]
    @claims = { "sub" => "user_new", "org_id" => "org_bank", "sid" => "session_new" }
    @profile = @client.profile("user_new")
  end

  test "mapped active SCIM subject creates one participant identity regardless of provider admin role" do
    admitted = resolve
    assert_equal "participant", admitted.role
    assert_equal "accepted", admitted.invitation_status
    assert_equal [ @cohort.id ], admitted.cohort_memberships.pluck(:cohort_id)
    assert_equal "user_new", admitted.authentication_identities.sole.subject
    assert_no_difference([ "User.count", "AuthenticationIdentity.count", "CohortMembership.count" ]) { assert_equal admitted.id, resolve.id }
    refute @workspace.allows?(admitted, :view)
    refute @organization.enterprise_memberships.find_by!(user: admitted).it_admin?
  end

  test "existing accepted email must be explicitly mapped and saved identity is not replaced" do
    existing = User.create!(clerk_id: "clerk_saved", email: @profile["email"], role: "participant")
    household = Household.create!(name: "Saved", created_by_user: existing)
    assert_no_difference([ "User.count", "AuthenticationIdentity.count" ]) do
      assert_raises(EnterpriseAccess::Denied) { resolve }
    end
    assert_equal "clerk_saved", existing.reload.clerk_id
    assert Household.exists?(household.id)
  end

  test "prebound existing subject is admitted under original local user id" do
    existing = User.create!(clerk_id: "clerk_original", email: @profile["email"], role: "participant")
    existing.authentication_identities.create!(provider: "workos", issuer: WorkosAuth.issuer, subject: "user_new")
    assert_no_difference("User.count") { assert_equal existing.id, resolve.id }
    assert_equal "clerk_original", existing.reload.clerk_id
  end

  test "unmapped group inactive membership unverified email and wrong org never admit" do
    @client.groups = []
    assert_no_difference("User.count") { assert_raises(EnterpriseAccess::Denied) { resolve } }
    @client.groups = [ { "id" => "directory_group_participants", "directory_id" => "directory_bank", "organization_id" => "org_bank" } ]
    @client.provider_memberships.first["status"] = "pending"
    assert_no_difference("User.count") { assert_raises(EnterpriseAccess::Denied) { resolve } }
    @client.provider_memberships.first["status"] = "active"
    @profile["email_verified"] = false
    assert_no_difference("User.count") { assert_raises(EnterpriseAccess::Denied) { resolve } }
    @profile["email_verified"] = true
    @claims["org_id"] = "org_other"
    assert_no_difference("User.count") { assert_raises(EnterpriseAccess::Denied) { resolve } }
  end

  test "vendor enablement must be confirmed and directory ids never become auth subjects" do
    @organization.update!(directory_provisioning_enabled: false)
    assert_no_difference("User.count") { assert_raises(EnterpriseAccess::Denied) { resolve } }
    assert_empty AuthenticationIdentity.where(subject: "directory_user_new")
  end

  test "password session rolls back new admission under SSO policy" do
    @client.session_rows.first["auth_method"] = "password"
    assert_no_difference([ "User.count", "AuthenticationIdentity.count", "EnterpriseMembership.count" ]) do
      assert_raises(EnterpriseAccess::Denied) { resolve }
    end
  end

  test "SCIM reconciliation materializes user once then JIT reuses identity" do
    assert_difference("User.count", 1) { Enterprise::Reconciliation.call(@organization, client: @client) }
    user = AuthenticationIdentity.find_by!(provider: "workos", subject: "user_new").user
    assert_no_difference("User.count") { assert_equal user.id, resolve.id }
  end

  test "explicit mapping attaches an earlier unbound membership without changing provider status" do
    membership = Enterprise::Provisioner.membership!(@organization, @client.provider_memberships.first)
    assert_nil membership.user
    existing = User.create!(clerk_id: "clerk_prebound", email: @profile["email"], role: "participant")
    existing.authentication_identities.create!(provider: "workos", issuer: WorkosAuth.issuer, subject: "user_new")
    timestamp = membership.provider_updated_at
    Enterprise::Provisioner.membership!(@organization, @client.provider_memberships.first)
    assert_equal existing.id, membership.reload.user_id
    assert_equal timestamp, membership.provider_updated_at
  end

  test "access hook binds exact prebound subject after an earlier sync" do
    membership = Enterprise::Provisioner.membership!(@organization, @client.provider_memberships.first)
    existing = User.create!(clerk_id: "clerk_prebound_access", email: @profile["email"], role: "participant")
    existing.authentication_identities.create!(provider: "workos", issuer: WorkosAuth.issuer, subject: "user_new")
    assert EnterpriseAccess.authorize!(user: existing, claims: @claims, client: @client)
    assert_equal existing.id, membership.reload.user_id
  end

  private
  def resolve
    Enterprise::Admission.resolve!(subject: "user_new", claims: @claims, profile: @profile, client: @client)
  end
end
