require "test_helper"
require_relative "../support/workos_auth_test_support"

class EnterpriseTargetScopeControllerTest < ActionController::TestCase
  tests Api::V1::EnterpriseOrganizationsController
  include WorkosAuthTestSupport

  class ScopedClient
    attr_accessor :active, :organization_id, :auth_method
    attr_reader :portal_calls
    def initialize
      @active = true
      @organization_id = "org_a"
      @auth_method = "password"
      @portal_calls = 0
    end
    def memberships(organization_id:, user_id:)
      [ { "id" => "om_it", "organization_id" => organization_id, "user_id" => user_id, "status" => active ? "active" : "inactive" } ]
    end
    def sessions(subject)
      [ { "id" => "session_it", "user_id" => subject, "organization_id" => organization_id, "status" => "active", "auth_method" => auth_method } ]
    end
    def portal(**_options)
      @portal_calls += 1
      "https://setup.workos.com?token=test"
    end
  end

  setup do
    @routes = ActionDispatch::Routing::RouteSet.new
    @routes.draw do
      scope "/api/v1", module: "api/v1" do
        resources :enterprise_organizations, only: [ :index, :show, :create, :update ] do
          post :portal, on: :member
          post :reconcile, on: :member
          get :audit, on: :member
          resources :memberships, only: [ :index, :update ], controller: "enterprise_memberships"
          resources :group_mappings, only: [ :index, :create, :update, :destroy ], controller: "enterprise_group_mappings"
        end
      end
    end
    key = SecureRandom.hex(6)
    @admin = User.create!(clerk_id: "admin_#{key}", email: "admin_#{key}@local.test", role: "admin")
    @it = User.create!(clerk_id: "it_#{key}", email: "it_#{key}@local.test", role: "participant")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(@admin)
    @a = EnterpriseOrganization.create!(name: "A", workos_organization_id: "org_a", coach_workspace: workspace, require_sso: false)
    @b = EnterpriseOrganization.create!(name: "B", workos_organization_id: "org_b", coach_workspace: workspace, require_sso: true)
    [ @a, @b ].each { |organization| organization.enterprise_memberships.create!(user: @it, workos_user_id: "user_it", status: "active", it_admin: true) }
    @it.authentication_identities.create!(provider: "workos", issuer: "https://api.workos.com/user_management/client_cfo", subject: "user_it")
    @admin.authentication_identities.create!(provider: "workos", issuer: "https://api.workos.com/user_management/client_cfo", subject: "user_admin")
    @client = ScopedClient.new
  end

  test "A password session cannot read B detail audit roster mappings or mint portal link" do
    with_it_session("org_a", role: "admin") do
      get :show, params: { id: @b.id }
      assert_target_signin_required
      get :audit, params: { id: @b.id }
      assert_target_signin_required
      post :portal, params: { id: @b.id, intent: "sso", return_url: "https://app.bank.test/?enterprise=1" }
      assert_target_signin_required
      post :reconcile, params: { id: @b.id }
      assert_target_signin_required
      @controller = Api::V1::EnterpriseMembershipsController.new
      get :index, params: { enterprise_organization_id: @b.id }
      assert_target_signin_required
      @controller = Api::V1::EnterpriseGroupMappingsController.new
      get :index, params: { enterprise_organization_id: @b.id }
      assert_target_signin_required
      assert_equal 0, @client.portal_calls
      assert_empty @b.enterprise_audit_events
    end
  end

  test "IT organization chooser reveals only minimal selection fields across memberships" do
    with_it_session("org_a") do
      get :index
      assert_response :success
      rows = JSON.parse(response.body).fetch("enterprise_organizations")
      assert_equal [ @a.id, @b.id ], rows.map { |row| row["id"] }
      assert rows.all? { |row| row.keys.sort == %w[id name workos_organization_id] }
    end
  end

  test "B revoked provider membership denies B administration despite locally active IT" do
    @client.organization_id = "org_b"
    @client.auth_method = "sso"
    @client.active = false
    with_it_session("org_b") do
      get :show, params: { id: @b.id }
      assert_response :forbidden
      post :portal, params: { id: @b.id, intent: "sso", return_url: "https://app.bank.test/?enterprise=1" }
      assert_response :forbidden
      assert_equal 0, @client.portal_calls
    end
  end

  test "ordinary nonenterprise WorkOS platform administrator retains target administration" do
    with_workos do
      with_workos_http do
        stub_method(Enterprise::Client, :new, @client) do
          request.headers["Authorization"] = "Bearer #{workos_token({ "sub" => "user_admin", "sid" => "session_admin" }) }"
          previous = ENV["WORKOS_ADMIN_PORTAL_RETURN_URLS"]
          ENV["WORKOS_ADMIN_PORTAL_RETURN_URLS"] = "https://app.bank.test/?enterprise=1"
          get :show, params: { id: @b.id }
          assert_response :success
          post :portal, params: { id: @b.id, intent: "sso", return_url: "https://app.bank.test/?enterprise=1" }
          assert_response :success
          assert_equal 1, @client.portal_calls
        ensure
          ENV["WORKOS_ADMIN_PORTAL_RETURN_URLS"] = previous
        end
      end
    end
  end

  test "cached global admin role cannot bypass target policy after persisted demotion" do
    resolver = WorkosIdentityResolver.method(:resolve!)
    admin = @admin
    with_workos do
      with_workos_http do
        replacement = lambda do |**options|
          user = resolver.call(**options)
          User.where(id: admin.id).update_all(role: "participant")
          user
        end
        stub_method(WorkosIdentityResolver, :resolve!, replacement) do
          request.headers["Authorization"] = "Bearer #{workos_token({ "sub" => "user_admin", "sid" => "session_admin" }) }"
          get :show, params: { id: @b.id }
          assert_response :not_found
        end
      end
    end
  end

  private
  def with_it_session(org_id, role: "member")
    with_workos do
      with_workos_http do
        stub_method(Enterprise::Client, :new, @client) do
          request.headers["Authorization"] = "Bearer #{workos_token({ "sub" => "user_it", "sid" => "session_it", "org_id" => org_id, "role" => role })}"
          yield
        end
      end
    end
  end

  def assert_target_signin_required
    assert_response :forbidden
    assert_equal "enterprise_organization_signin_required", JSON.parse(response.body)["code"]
  end
end
