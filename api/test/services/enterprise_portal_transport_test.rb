require "test_helper"

class EnterprisePortalTransportTest < ActiveSupport::TestCase
  setup do
    key = SecureRandom.hex(6)
    @admin = User.create!(clerk_id: "admin_#{key}", email: "#{key}@bank.test", role: "admin")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(@admin)
    @organization = EnterpriseOrganization.create!(name: "Bank", workos_organization_id: "org_bank", coach_workspace: workspace)
    @previous = ENV["WORKOS_ADMIN_PORTAL_RETURN_URLS"]
    ENV["WORKOS_ADMIN_PORTAL_RETURN_URLS"] = "http://localhost:5186/?enterprise=1"
    @client = Object.new
  end

  teardown do
    ENV["WORKOS_ADMIN_PORTAL_RETURN_URLS"] = @previous
  end

  test "explicit staging return port is allowed while portal credentials require HTTPS port443" do
    @client.define_singleton_method(:portal) { |**_options| "https://setup.workos.com:8443?token=test" }
    assert_no_difference("EnterpriseAuditEvent.count") { assert_raises(Enterprise::Client::Unavailable) { portal } }
    @client.define_singleton_method(:portal) { |**_options| "https://setup.workos.com:443?token=test" }
    assert_equal "https://setup.workos.com:443?token=test", portal[:url]
  end

  test "provider malformed URL types and syntax fail as unavailable" do
    [ nil, [], "https://setup.workos.com:invalid?token=test" ].each do |url|
      @client.define_singleton_method(:portal) { |**_options| url }
      assert_no_difference("EnterpriseAuditEvent.count") { assert_raises(Enterprise::Client::Unavailable) { portal } }
    end
  end

  private
  def portal
    Enterprise::Portal.call(organization: @organization, user: @admin, intent: "sso", return_url: "http://localhost:5186/?enterprise=1", client: @client)
  end
end
