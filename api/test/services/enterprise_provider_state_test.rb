require_relative "enterprise_provisioning_test"

class EnterpriseProviderStateTest < ActiveSupport::TestCase
  setup do
    key = SecureRandom.hex(6)
    admin = User.create!(clerk_id: "admin_#{key}", email: "admin_#{key}@local.test", role: "admin")
    @user = User.create!(clerk_id: "participant_#{key}", email: "#{key}@local.test", role: "participant")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(admin)
    cohort = Cohort.create!(name: "Cached bank", created_by_user: admin, coach_workspace: workspace, status: "active")
    @organization = EnterpriseOrganization.create!(name: "Bank", coach_workspace: workspace, workos_organization_id: "org_bank", directory_id: "directory_bank")
    @membership = @organization.enterprise_memberships.create!(user: @user, workos_user_id: "user_participant", status: "active")
    @organization.enterprise_group_mappings.create!(workos_group_id: "directory_group_participants", cohort: cohort)
    @client = EnterpriseProvisioningTest::FakeClient.new
    @client.provider_memberships = [ { "id" => "om_bank", "user_id" => "user_participant", "organization_id" => "org_bank", "status" => "active", "updated_at" => "2026-10-06T20:00:00Z" } ]
    @client.users = [ { "id" => "directory_user_person", "directory_id" => "directory_bank", "organization_id" => "org_bank", "email" => "user_participant@bank.test", "state" => "active", "updated_at" => "2026-10-06T20:00:00Z" } ]
    @client.groups = [ { "id" => "directory_group_participants", "directory_id" => "directory_bank", "organization_id" => "org_bank" } ]
    @client.session_rows = [ { "id" => "session_valid", "user_id" => "user_participant", "organization_id" => "org_bank", "status" => "active", "auth_method" => "sso" } ]
    @claims = { "sub" => "user_participant", "org_id" => "org_bank", "sid" => "session_valid" }
    @cache = ActiveSupport::Cache::MemoryStore.new
  end

  test "verified provider cache avoids repeated HTTP and expires within thirty seconds" do
    freeze_time do
      assert authorize
      calls = @client.requests.length
      travel 29.seconds
      assert authorize
      assert_equal calls, @client.requests.length
      travel 2.seconds
      assert authorize
      assert_operator @client.requests.length, :>, calls
    end
  end

  test "local deactivation revocation and group unassignment deny while provider proof is cached" do
    assert authorize
    calls = @client.requests.length
    @membership.update!(locally_revoked: true)
    assert_raises(EnterpriseAccess::Denied) { authorize }
    assert_equal calls, @client.requests.length
    @membership.update!(locally_revoked: false, status: "inactive")
    assert_raises(EnterpriseAccess::Denied) { authorize }
    assert_equal calls, @client.requests.length
    @membership.update!(status: "active")
    assert authorize
    calls = @client.requests.length
    EnterpriseDirectoryGroupMembership.update_all(active: false)
    assert_raises(EnterpriseAccess::Denied) { authorize }
    assert_equal calls, @client.requests.length
  end

  test "provider outage after cache expiry fails closed without stale permission" do
    freeze_time do
      assert authorize
      @client.fail = true
      assert authorize
      travel 31.seconds
      assert_raises(Enterprise::Client::Unavailable) { authorize }
      assert_raises(Enterprise::Client::Unavailable) { authorize }
    end
  end

  test "cached proof cannot be reused by another session or weaker organization policy" do
    assert authorize
    assert_raises(EnterpriseAccess::Denied) { authorize(@claims.merge("sid" => "session_other")) }
    @organization.update!(require_sso: false)
    @client.session_rows.first["auth_method"] = "password"
    assert authorize
    @organization.update!(require_sso: true)
    error = assert_raises(EnterpriseAccess::Denied) { authorize }
    assert_equal "enterprise_sso_required", error.code
  end

  test "reconciliation fetches complete snapshot before holding organization lock" do
    locked = false
    original_lock = @organization.method(:with_lock)
    @organization.define_singleton_method(:with_lock) do |&block|
      original_lock.call do
        locked = true
        begin
          block.call
        ensure
          locked = false
        end
      end
    end
    request = @client.method(:request)
    test = self
    @client.define_singleton_method(:request) do |*args, **options|
      test.refute locked, "Provider HTTP must not hold the organization row lock"
      request.call(*args, **options)
    end
    Enterprise::Reconciliation.call(@organization, client: @client)
    assert @organization.reload.last_reconciled_at
  end

  test "stale reconciliation cannot restore a newer membership deactivation" do
    groups = @client.method(:directory_groups)
    membership = @membership
    @client.define_singleton_method(:directory_groups) do |**options|
      membership.update!(status: "inactive", provider_updated_at: 1.second.from_now)
      groups.call(**options)
    end
    assert_raises(Enterprise::Client::Unavailable) { Enterprise::Reconciliation.call(@organization, client: @client) }
    assert_equal "inactive", @membership.reload.status
    assert_empty @user.cohort_memberships
  end

  test "worker batch reconciles one authoritative snapshot per organization" do
    events = 2.times.map do |index|
      EnterpriseSyncEvent.create!(workos_event_id: "event_#{index}", event_type: "organization_membership.updated", payload: @client.provider_memberships.first, occurred_at: Time.current)
    end
    reconciled = []
    events.each { |event| Enterprise::EventProcessor.call(event, client: @client, reconciled_organization_ids: reconciled) }
    reads = @client.requests.count { |request| request[1] == "/organizations/org_bank" }
    assert_equal 1, reads
    assert events.all? { |event| event.reload.processed_at }
  end

  private
  def authorize(claims = @claims)
    EnterpriseAccess.authorize!(user: @user, claims: claims, client: @client, cache: @cache)
  end
end
