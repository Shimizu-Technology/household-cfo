require "test_helper"

class EnterpriseOrganizationsControllerTest < ActionController::TestCase
  tests Api::V1::EnterpriseOrganizationsController

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
    assert_response :not_found
  end

  private
  def new_user(role = "participant")
    key = SecureRandom.hex(6)
    User.create!(clerk_id: "test_#{key}", email: "#{key}@local.test", role: role)
  end
  def authenticate(user)
    request.headers["Authorization"] = "Bearer test_token_#{user.id}"
  end
end
