require "test_helper"
require_relative "../support/workos_auth_test_support"

class EnterpriseOrganizationsControllerTest < ActionController::TestCase
  tests Api::V1::EnterpriseOrganizationsController
  include WorkosAuthTestSupport

  setup do
    @routes = ActionDispatch::Routing::RouteSet.new
    @routes.draw do
      scope "/api/v1", module: "api/v1" do
        resources :enterprise_organizations, only: [ :index, :show, :create, :update ] do
          post :portal, on: :member
          get :audit, on: :member
        end
      end
    end
    @admin = new_user("admin")
    @it = new_user
    @workspace = CoachWorkspaces::Provisioner.ensure_for!(@admin)
    @organization = EnterpriseOrganization.create!(name: "Bank", coach_workspace: @workspace, workos_organization_id: "org_bank")
    @membership = @organization.enterprise_memberships.create!(user: @it, workos_user_id: "user_it", status: "active", it_admin: true)
    @it.authentication_identities.create!(provider: "workos", issuer: "https://api.workos.com/user_management/client_cfo", subject: "user_it")
    authenticate(@it)
  end

  test "IT lists and sees only designated enterprise with no finance payload" do
    other = EnterpriseOrganization.create!(name: "Other", coach_workspace: @workspace, workos_organization_id: "org_other")
    get :index
    assert_response :success
    json = JSON.parse(response.body)
    assert_equal [ @organization.id ], json["enterprise_organizations"].map { |row| row["id"] }
    refute_match(/household|balance|transactions|coach_workspaces/, response.body)
    get :show, params: { id: other.id }
    assert_response :not_found
  end

  test "IT cannot change organization policy or promote itself" do
    patch :update, params: { id: @organization.id, enterprise_organization: { require_sso: false, active: false } }
    assert_response :forbidden
    assert @organization.reload.require_sso?
    assert @organization.active?
    assert_equal "participant", @it.reload.role
  end

  test "unassigned user and missing authentication cannot access scoped administration" do
    authenticate(new_user)
    get :show, params: { id: @organization.id }
    assert_response :not_found
    request.headers["Authorization"] = nil
    get :index
    assert_response :unauthorized
  end

  test "platform administrator creates and configures organization but identity cannot transfer" do
    authenticate(@admin)
    post :create, params: { enterprise_organization: { name: "New bank", coach_workspace_id: @workspace.id, workos_organization_id: "org_new", directory_provisioning_enabled: true } }
    assert_response :created
    organization = EnterpriseOrganization.find_by!(workos_organization_id: "org_new")
    refute organization.directory_provisioning_enabled?
    patch :update, params: { id: organization.id, enterprise_organization: { directory_provisioning_enabled: true, workos_organization_id: "org_other" } }
    assert_response :success
    assert organization.reload.directory_provisioning_enabled?
    assert_equal "org_new", organization.workos_organization_id
  end

  test "inactive IT membership disappears from scope" do
    @membership.update!(status: "inactive")
    get :show, params: { id: @organization.id }
    assert_includes [ 403, 404 ], response.status
  end

  def process(action, **options)
    if @signed_user
      with_workos do
        with_workos_http do
          client = Object.new
          client.define_singleton_method(:memberships) do |organization_id:, user_id:|
            [ { "organization_id" => organization_id, "user_id" => user_id, "status" => "active" } ]
          end
          client.define_singleton_method(:sessions) do |subject|
            [ { "id" => "session_it", "user_id" => subject, "organization_id" => "org_bank", "status" => "active", "auth_method" => "sso" } ]
          end
          stub_method(Enterprise::Client, :new, client) do
            request.headers["Authorization"] = "Bearer #{workos_token({ "sub" => "user_it", "sid" => "session_it", "org_id" => "org_bank" })}"
            super(action, **options)
          end
        end
      end
    else
      previous = ENV["AUTH_PROVIDER"]
      begin
        ENV["AUTH_PROVIDER"] = "clerk"
        super(action, **options)
      ensure
        ENV["AUTH_PROVIDER"] = previous
      end
    end
  end

  private
  def new_user(role = "participant")
    key = SecureRandom.hex(6)
    User.create!(clerk_id: "test_#{key}", email: "#{key}@local.test", role: role)
  end
  def authenticate(user)
    @signed_user = user == @it
    request.headers["Authorization"] = "Bearer test_token_#{user.id}"
  end
end
