require "test_helper"
require_relative "../support/workos_auth_test_support"
require_relative "../services/enterprise_provisioning_test"

class ApiV1WorkosEnterpriseIntegrationTest < ActionDispatch::IntegrationTest
  include WorkosAuthTestSupport

  class IntegrationClient < EnterpriseProvisioningTest::FakeClient
    def profile(subject)
      { "id" => subject, "email" => "workos@example.com", "email_verified" => true,
        "first_name" => "Fictional", "last_name" => "Participant" }
    end
  end

  setup do
    operator = User.create!(clerk_id: "operator_#{SecureRandom.hex(6)}", email: "#{SecureRandom.hex(6)}@fictional.test", role: "admin")
    @workspace = CoachWorkspaces::Provisioner.ensure_for!(operator)
    @cohort = Cohort.create!(name: "Enterprise integration", coach_workspace: @workspace, created_by_user: operator, status: "active")
    @organization = EnterpriseOrganization.create!(name: "Fictional bank", coach_workspace: @workspace,
      workos_organization_id: "org_bank", directory_id: "directory_bank", directory_provisioning_enabled: true)
    @organization.enterprise_group_mappings.create!(workos_group_id: "directory_group_participants", cohort: @cohort)
    @client = IntegrationClient.new
    @client.provider_memberships = [ { "id" => "om_test", "user_id" => "user_test", "organization_id" => "org_bank", "status" => "active", "updated_at" => Time.current.iso8601 } ]
    @client.users = [ { "id" => "directory_user_test", "directory_id" => "directory_bank", "organization_id" => "org_bank", "email" => "workos@example.com", "state" => "active", "updated_at" => Time.current.iso8601 } ]
    @client.groups = [ { "id" => "directory_group_participants", "directory_id" => "directory_bank", "organization_id" => "org_bank" } ]
    @client.session_rows = [ { "id" => "session_test", "user_id" => "user_test", "organization_id" => "org_bank", "status" => "active", "auth_method" => "sso" } ]
  end

  test "signed directory admission crosses real auth route once and grants only the mapped participant program" do
    provider_requests do
      assert_difference("User.count", 1) { get "/api/v1/auth/me", headers: token_headers }
      assert_response :success
      payload = response.parsed_body.fetch("user")
      user = User.find(payload.fetch("id"))
      assert_equal "participant", payload.fetch("role")
      refute payload.fetch("is_admin")
      refute payload.fetch("is_staff")
      assert_equal [ @cohort.id ], user.cohort_memberships.pluck(:cohort_id)
      assert_empty payload.fetch("enterprise_access").fetch("organizations")
      assert_equal "user_test", user.authentication_identities.sole.subject
      assert_no_difference("User.count") { get "/api/v1/auth/me", headers: token_headers }
      assert_response :success
      get "/api/v1/admin/users", headers: token_headers
      assert_response :forbidden
    end
  end

  test "an inactive bound enterprise identity denies both identity and finance routes while retaining household associations" do
    user = saved_user
    household = Household.create!(name: "Preserved private household", created_by_user: user)
    HouseholdMembership.create!(household: household, user: user, role: "owner")
    provider_requests do
      bind(user)
      @organization.enterprise_memberships.create!(user: user, workos_user_id: "user_test", status: "inactive")
      assert_no_difference([ "User.count", "Household.count", "HouseholdMembership.count" ]) do
        get "/api/v1/auth/me", headers: token_headers
        assert_response :forbidden
        get "/api/v1/profile", headers: token_headers
        assert_response :forbidden
      end
      assert_equal household.id, user.households.sole.id
    end
  end

  test "designated IT remains a participant and cannot gain platform rights from a provider admin claim" do
    user = saved_user
    provider_requests do
      bind(user)
      @organization.enterprise_memberships.create!(user: user, workos_user_id: "user_test", status: "active", it_admin: true)
      get "/api/v1/auth/me", headers: token_headers("role" => "admin")
      assert_response :success
      payload = response.parsed_body.fetch("user")
      refute payload.fetch("is_admin")
      assert payload.fetch("enterprise_access").fetch("organizations").sole.fetch("it_admin")
      get "/api/v1/enterprise_organizations/#{@organization.id}", headers: token_headers
      assert_response :success
      refute_match(/household|balance|transactions/, response.body)
      get "/api/v1/admin/users", headers: token_headers
      assert_response :forbidden
    end
  end

  test "provider outage is recoverable unavailable rather than a revoked invitation" do
    user = saved_user
    provider_requests do
      bind(user)
      @organization.enterprise_memberships.create!(user: user, workos_user_id: "user_test", status: "active", it_admin: true)
      @client.define_singleton_method(:memberships) { |**_options| raise Enterprise::Client::Unavailable }
      get "/api/v1/auth/me", headers: token_headers
      assert_response :service_unavailable
      assert_equal "accepted", user.reload.invitation_status
    end
  end

  test "Clerk rollback cannot bypass an enterprise membership SSO requirement" do
    user = saved_user
    @organization.enterprise_memberships.create!(user: user, workos_user_id: "user_test", status: "active", it_admin: true)
    get "/api/v1/auth/me", headers: { "Authorization" => "Bearer test_token_#{user.id}" }
    assert_response :forbidden
    assert_equal "accepted", user.reload.invitation_status
  end

  private

  def saved_user
    User.create!(clerk_id: "preserved_clerk", email: "workos@example.com", role: "participant", invitation_status: "accepted")
  end

  def bind(user)
    user.authentication_identities.create!(provider: "workos", issuer: WorkosAuth.issuer, subject: "user_test")
  end

  def token_headers(overrides = {})
    { "Authorization" => "Bearer #{workos_token({ 'org_id' => 'org_bank' }.merge(overrides))}" }
  end

  def provider_requests(&block)
    with_workos do
      with_workos_http do
        stub_method(Enterprise::Client, :new, @client, &block)
      end
    end
  end
end
