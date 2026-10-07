require "test_helper"

class EnterpriseProvisioningTest < ActiveSupport::TestCase
  class FakeClient < Enterprise::Client
    attr_accessor :provider_memberships, :users, :groups, :session_rows, :pages, :requests, :fail, :portal_url
    attr_writer :directory
    def initialize
      @provider_memberships = []
      @users = []
      @groups = []
      @session_rows = []
      @pages = []
      @portal_url = "https://setup.workos.com?token=secret"
      @requests = []
      @directory = { "id" => "directory_bank", "organization_id" => "org_bank", "state" => "linked" }
    end
    def request(method, path, **options)
      @requests << [ method, path, options ]
      raise Enterprise::Client::Unavailable, "Fake provider failure" if fail
      if path.start_with?("/directories/")
        raise Enterprise::Client::NotFound, "Fake deleted directory" unless @directory
        return @directory
      end
      { "id" => "org_bank" }
    end
    def directory(directory_id = nil)
      directory_id ? super(directory_id) : @directory
    end
    def list(path, **options)
      request(:get, path, **options)
      path == "/directories" ? [ directory ].compact : [ { "organization_id" => "org_bank", "state" => "active" } ]
    end
    def memberships(**options)
      request(:get, "/memberships", **options)
      provider_memberships.select { |row| !options[:user_id] || row["user_id"] == options[:user_id] }
    end
    def profile(subject)
      { "id" => subject, "email" => "#{subject}@bank.test", "email_verified" => true, "first_name" => "Participant" }
    end
    def directory_users(**options)
      request(:get, "/directory_users", **options)
      users.select { |row| !options[:email] || row["email"] == options[:email] }
    end
    def directory_groups(**options)
      request(:get, "/directory_groups", **options)
      groups
    end
    def sessions(subject)
      session_rows
    end
    def events(after: nil)
      request(:get, "/events", after: after)
      pages.shift || { "data" => [] }
    end
    def portal(**options)
      request(:post, "/portal/generate_link", **options)
      portal_url
    end
  end

  setup do
    @admin = user("admin")
    @participant = user
    @workspace = CoachWorkspaces::Provisioner.ensure_for!(@admin)
    @cohort = Cohort.create!(created_by_user: @admin, coach_workspace: @workspace, name: "Bank", status: "active")
    @organization = EnterpriseOrganization.create!(name: "Bank", workos_organization_id: "org_bank", coach_workspace: @workspace, directory_id: "directory_bank", directory_state: "linked", directory_provisioning_enabled: true)
    @membership = @organization.enterprise_memberships.create!(user: @participant, workos_user_id: "user_participant", status: "active")
    @mapping = @organization.enterprise_group_mappings.create!(workos_group_id: "directory_group_participants", cohort: @cohort)
    @client = FakeClient.new
    @client.provider_memberships = [ provider_membership ]
    @client.users = [ directory_user ]
    @client.groups = [ group ]
    @client.session_rows = [ { "id" => "session_valid", "user_id" => "user_participant", "organization_id" => "org_bank", "status" => "active", "auth_method" => "sso" } ]
    Enterprise::Provisioner.refresh_directory_for!(@organization, @membership, @client.profile("user_participant"), client: @client)
  end

  test "IT scope does not grant coach platform or finance visibility" do
    @membership.update!(it_admin: true)
    assert_includes EnterpriseOrganization.visible_to(@participant), @organization
    refute @participant.staff?
    refute @workspace.allows?(@participant, :view)
    assert_equal "participant", @participant.reload.role
    assert_equal [ @cohort.id ], @participant.cohort_memberships.pluck(:cohort_id)
  end

  test "wrong tenant missing organization and spoofed SSO claims are denied" do
    assert EnterpriseAccess.authorize!(user: @participant, claims: claims, client: @client)
    assert_raises(EnterpriseAccess::Denied) { EnterpriseAccess.authorize!(user: @participant, claims: claims.merge("org_id" => "org_other"), client: @client) }
    assert_raises(EnterpriseAccess::Denied) { EnterpriseAccess.authorize!(user: @participant, claims: claims.except("org_id"), client: @client) }
    @client.session_rows.first["auth_method"] = "password"
    error = assert_raises(EnterpriseAccess::Denied) { EnterpriseAccess.authorize!(user: @participant, claims: claims.merge("auth_method" => "sso"), client: @client) }
    assert_equal "enterprise_sso_required", error.code
  end

  test "revoked and inactive access denies even an existing valid JWT" do
    @membership.update!(locally_revoked: true)
    assert_raises(EnterpriseAccess::Denied) { EnterpriseAccess.authorize!(user: @participant, claims: claims, client: @client) }
    @membership.update!(locally_revoked: false, status: "inactive")
    assert_raises(EnterpriseAccess::Denied) { EnterpriseAccess.authorize!(user: @participant, claims: claims, client: @client) }
  end

  test "regular nonenterprise users preserve independent invitation policy" do
    assert EnterpriseAccess.authorize!(user: user, claims: { "sub" => "regular" }, client: @client)
  end

  test "unassignment immediately denies access and removes only managed enrollment" do
    manual = Cohort.create!(created_by_user: @admin, coach_workspace: @workspace, name: "Manual", status: "active")
    manual_enrollment = CohortMembership.create!(cohort: manual, user: @participant, role: "participant")
    @client.groups = []
    assert_raises(EnterpriseAccess::Denied) { EnterpriseAccess.authorize!(user: @participant, claims: claims, client: @client) }
    refute CohortMembership.exists?(cohort: @cohort, user: @participant)
    assert CohortMembership.exists?(manual_enrollment.id)
  end

  test "deprovision and conservative reactivation retain financial data and clear IT" do
    household = Household.create!(created_by_user: @participant, name: "Saved household")
    @membership.update!(it_admin: true)
    @client.provider_memberships.first["status"] = "inactive"
    Enterprise::Reconciliation.call(@organization, client: @client)
    assert_equal "inactive", @membership.reload.status
    refute @membership.it_admin?
    assert Household.exists?(household.id)
    assert User.exists?(@participant.id)
    refute CohortMembership.exists?(cohort: @cohort, user: @participant)
    @client.provider_memberships.first["status"] = "active"
    Enterprise::Reconciliation.call(@organization, client: @client)
    assert_equal "active", @membership.reload.status
    refute @membership.it_admin?
    assert_equal "participant", @participant.reload.role
    assert Household.exists?(household.id)
  end

  test "mapping enforces workspace boundary and participant grant cannot promote user" do
    another = user("admin")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(another)
    cohort = Cohort.create!(created_by_user: another, coach_workspace: workspace, name: "Other", status: "active")
    mapping = @organization.enterprise_group_mappings.new(workos_group_id: "directory_group_other", cohort: cohort)
    refute mapping.valid?
    @participant.update!(role: "coach")
    Enterprise::Enrollment.reconcile!(@membership)
    assert_nil @workspace.membership_for(@participant)
  end

  test "manual participant removal does not become impossible due to provenance" do
    enrollment = CohortMembership.find_by!(cohort: @cohort, user: @participant)
    enrollment.destroy!
    assert_empty @membership.enterprise_cohort_grants.reload
  end

  test "out of order membership payload cannot reactivate deprovisioned membership" do
    Enterprise::Provisioner.membership!(@organization, provider_membership.merge("status" => "inactive", "updated_at" => "2026-10-07T20:10:00Z"))
    Enterprise::Provisioner.membership!(@organization, provider_membership.merge("updated_at" => "2026-10-07T20:00:00Z"))
    assert_equal "inactive", @membership.reload.status
  end

  test "event replay reconciles current provider state rather than stale active payload" do
    @client.provider_memberships.first["status"] = "inactive"
    event = create_event("event_old", "organization_membership.updated", provider_membership)
    Enterprise::EventProcessor.call(event, client: @client)
    assert_equal "inactive", @membership.reload.status
    assert_no_difference("EnterpriseAuditEvent.count") { Enterprise::EventProcessor.call(event, client: @client) }
    event.update!(processed_at: nil)
    Enterprise::EventProcessor.call(event, client: @client)
    assert_equal "inactive", @membership.reload.status
  end

  test "durable cursor inbox duplicate polling and failed worker restart are safe" do
    data = { "id" => "event_one", "event" => "organization_membership.updated", "data" => provider_membership, "created_at" => "2026-10-07T20:00:00Z" }
    @client.pages = [ { "data" => [ data ] }, { "data" => [] } ]
    Enterprise::EventPoll.call(client: @client)
    assert_equal "event_one", EnterpriseSyncCursor.find_by!(name: "workos").cursor
    event = EnterpriseSyncEvent.find_by!(workos_event_id: "event_one")
    @client.fail = true
    assert_raises(Enterprise::Client::Unavailable) { Enterprise::EventProcessor.call(event, client: @client) }
    assert_nil event.reload.processed_at
    assert_equal 1, event.attempts
    assert_equal "Enterprise::Client::Unavailable", event.last_error
    @client.fail = false
    Enterprise::EventProcessor.call(event, client: @client)
    assert event.reload.processed_at
    assert_equal 2, event.attempts
    assert_nil event.last_error
    EnterpriseSyncCursor.find_by!(name: "workos").update!(cursor: nil)
    @client.pages = [ { "data" => [ data ] }, { "data" => [] } ]
    assert_no_difference("EnterpriseSyncEvent.count") { Enterprise::EventPoll.call(client: @client) }
  end

  test "authoritative reconciliation recovers missed deletion" do
    @client.provider_memberships = []
    Enterprise::Reconciliation.call(@organization, client: @client)
    assert_equal "inactive", @membership.reload.status
    refute CohortMembership.exists?(cohort: @cohort, user: @participant)
  end

  test "portal tenant is authorized record intent and return URL are constrained" do
    previous = ENV["WORKOS_ADMIN_PORTAL_RETURN_URLS"]
    ENV["WORKOS_ADMIN_PORTAL_RETURN_URLS"] = "https://cfo.example.test/enterprise"
    arguments = { organization: @organization, user: @participant, intent: "sso", return_url: "https://cfo.example.test/enterprise", client: @client, claims: claims, provider: "workos" }
    assert_raises(EnterpriseAccess::Denied) { Enterprise::Portal.call(**arguments) }
    @membership.update!(it_admin: true)
    result = Enterprise::Portal.call(**arguments)
    assert_equal "https://setup.workos.com?token=secret", result[:url]
    assert_in_delta 300, Time.iso8601(result[:expires_at]) - Time.current, 2
    assert_raises(ArgumentError) { Enterprise::Portal.call(**arguments.merge(intent: "audit_logs")) }
    assert_raises(ArgumentError) { Enterprise::Portal.call(**arguments.merge(return_url: "https://evil.test/enterprise")) }
    event = @organization.enterprise_audit_events.last
    assert_equal({ "intent" => "sso" }, event.metadata)
    refute_includes event.attributes.to_json, "secret"
  ensure
    ENV["WORKOS_ADMIN_PORTAL_RETURN_URLS"] = previous
  end

  test "directory data cannot cross tenant or directory boundaries" do
    assert_raises(EnterpriseAccess::Denied) { Enterprise::Provisioner.directory_user!(@organization, directory_user.merge("organization_id" => "org_other")) }
    assert_raises(EnterpriseAccess::Denied) { Enterprise::Provisioner.directory_user!(@organization, directory_user.merge("directory_id" => "directory_other")) }
    event = create_event("event_cross", "dsync.group.user_added", { "user" => directory_user, "group" => group.merge("organization_id" => "org_other") })
    assert_raises(EnterpriseAccess::Denied) { Enterprise::EventProcessor.call(event, client: @client) }
  end

  test "database rejects mappings that bypass the workspace validation" do
    other = user("admin")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(other)
    cohort = Cohort.create!(created_by_user: other, coach_workspace: workspace, name: "Other database", status: "active")
    assert_raises(ActiveRecord::StatementInvalid) do
      EnterpriseGroupMapping.transaction(requires_new: true) { @mapping.update_columns(cohort_id: cohort.id) }
    end
    assert_equal @cohort.id, @mapping.reload.cohort_id
  end

  test "schema dumping preserves enterprise database boundary functions" do
    stream = StringIO.new
    ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, stream)
    assert_includes stream.string, "enforce_enterprise_mapping_boundary"
    assert_includes stream.string, "enforce_enterprise_directory_boundary"
    assert_includes stream.string, "enforce_enterprise_grant_boundary"
  end

  test "deactivated coach cannot automatically recover prior privilege on reprovision" do
    @participant.update!(role: "coach")
    Enterprise::Provisioner.membership!(@organization, provider_membership.merge("status" => "inactive", "updated_at" => "2026-10-07T20:10:00Z"))
    assert @membership.reload.locally_revoked?
    Enterprise::Provisioner.membership!(@organization, provider_membership.merge("updated_at" => "2026-10-07T20:20:00Z"))
    assert @membership.reload.locally_revoked?
    assert_raises(EnterpriseAccess::Denied) { EnterpriseAccess.authorize!(user: @participant, claims: claims, client: @client) }
  end

  test "portal response refuses lookalike host and permits explicit custom hostname" do
    previous_urls = ENV["WORKOS_ADMIN_PORTAL_RETURN_URLS"]
    previous_host = ENV["WORKOS_ADMIN_PORTAL_HOSTNAME"]
    ENV["WORKOS_ADMIN_PORTAL_RETURN_URLS"] = "https://cfo.example.test/?enterprise=1"
    @membership.update!(it_admin: true)
    arguments = { organization: @organization, user: @participant, intent: "dsync", return_url: "https://cfo.example.test/?enterprise=1", client: @client, claims: claims, provider: "workos" }
    @client.portal_url = "https://setup.workos.com.evil.test?token=secret"
    assert_raises(Enterprise::Client::Unavailable) { Enterprise::Portal.call(**arguments) }
    ENV["WORKOS_ADMIN_PORTAL_HOSTNAME"] = "setup.bank.test"
    @client.portal_url = "https://setup.bank.test?token=secret"
    assert_equal @client.portal_url, Enterprise::Portal.call(**arguments)[:url]
  ensure
    ENV["WORKOS_ADMIN_PORTAL_RETURN_URLS"] = previous_urls
    ENV["WORKOS_ADMIN_PORTAL_HOSTNAME"] = previous_host
  end

  test "worker retains failed event and continues independent events" do
    previous_key = ENV["WORKOS_API_KEY"]
    previous_enabled = ENV["WORKOS_SYNC_ENABLED"]
    ENV["WORKOS_SYNC_ENABLED"] = "true"
    ENV["WORKOS_API_KEY"] = "test_configuration"
    failed = create_event("event_a", "organization_membership.updated", provider_membership)
    complete = create_event("event_b", "organization_membership.updated", provider_membership)
    original_poll = Enterprise::EventPoll.method(:call)
    original_process = Enterprise::EventProcessor.method(:call)
    Enterprise::EventPoll.define_singleton_method(:call) { nil }
    client = @client
    Enterprise::EventProcessor.define_singleton_method(:call) do |event, **options|
      client.fail = event.workos_event_id == "event_a"
      original_process.call(event, client: client, **options)
    end
    EnterpriseSyncJob.perform_now
    assert_nil failed.reload.processed_at
    assert_equal "Enterprise::Client::Unavailable", failed.last_error
    assert complete.reload.processed_at
    assert_equal 1, failed.attempts
  ensure
    Enterprise::EventPoll.define_singleton_method(:call, original_poll) if original_poll
    Enterprise::EventProcessor.define_singleton_method(:call, original_process) if original_process
    ENV["WORKOS_API_KEY"] = previous_key
    ENV["WORKOS_SYNC_ENABLED"] = previous_enabled
  end

  test "scheduler provisioning is opt in even with API credentials installed" do
    previous_key = ENV["WORKOS_API_KEY"]
    previous_enabled = ENV["WORKOS_SYNC_ENABLED"]
    ENV["WORKOS_API_KEY"] = "test_configuration"
    ENV.delete("WORKOS_SYNC_ENABLED")
    original_poll = Enterprise::EventPoll.method(:call)
    Enterprise::EventPoll.define_singleton_method(:call) { raise "Disabled scheduler called WorkOS" }
    assert_no_difference([ "EnterpriseSyncEvent.count", "EnterpriseAuditEvent.count", "User.count" ]) { EnterpriseSyncJob.perform_now }
    ENV["WORKOS_SYNC_ENABLED"] = "false"
    assert_no_difference("EnterpriseSyncEvent.count") { EnterpriseSyncJob.perform_now }
  ensure
    Enterprise::EventPoll.define_singleton_method(:call, original_poll) if original_poll
    ENV["WORKOS_API_KEY"] = previous_key
    ENV["WORKOS_SYNC_ENABLED"] = previous_enabled
  end

  test "nonlinked reconciliation removes only managed grants and preserves finances manual enrollment and IT scope" do
    household = Household.create!(created_by_user: @participant, name: "Saved private finances")
    HouseholdMembership.create!(household: household, user: @participant, role: "owner")
    account = Account.create!(household: household, label: "Savings history", account_type: "savings", balance_cents: 54321)
    manual_cohort = Cohort.create!(created_by_user: @admin, coach_workspace: @workspace, name: "Manual history", status: "active")
    manual = CohortMembership.create!(cohort: manual_cohort, user: @participant, role: "participant")
    @membership.update!(it_admin: true)
    %w[unlinked deleting invalid_credentials validating unknown].each do |state|
      @client.directory["state"] = state
      assert_no_difference([ "User.count", "Household.count", "HouseholdMembership.count", "Account.count" ]) do
        Enterprise::Reconciliation.call(@organization, client: @client)
      end
      assert_equal state, @organization.reload.directory_state
      assert_empty Enterprise::Enrollment.allowed_cohort_ids(@membership.reload)
      assert_empty @membership.enterprise_cohort_grants
      refute CohortMembership.exists?(cohort: @cohort, user: @participant)
      assert CohortMembership.exists?(manual.id)
      assert_equal "active", @membership.status
      assert @membership.it_admin?
      assert_equal "participant", @participant.reload.role
      assert_equal 54321, account.reload.balance_cents
      assert_equal [ household.id ], @participant.households.pluck(:id)
    end
    @client.directory["state"] = "linked"
    Enterprise::Reconciliation.call(@organization, client: @client)
    assert CohortMembership.exists?(cohort: @cohort, user: @participant, role: "participant")
    assert CohortMembership.exists?(manual.id)
    assert_equal 54321, account.reload.balance_cents
  end

  test "completed directory deletion ignores retained users and groups while preserving local identity" do
    @client.directory = nil
    @client.define_singleton_method(:profile) { |_subject| raise "Deleted directory must not admit by email domain" }
    Enterprise::Reconciliation.call(@organization, client: @client)
    assert_nil @organization.reload.directory_id
    assert_equal "unconfigured", @organization.directory_state
    assert_empty Enterprise::Enrollment.allowed_cohort_ids(@membership.reload)
    assert_empty @membership.enterprise_cohort_grants
    assert User.exists?(@participant.id)
    assert_equal "active", @membership.status
    assert_raises(EnterpriseAccess::Denied) { EnterpriseAccess.authorize!(user: @participant, claims: claims, client: @client) }
  end

  test "failed authoritative directory read preserves the last linked state and assignments" do
    @client.fail = true
    before = @organization.attributes.slice("directory_id", "directory_state", "last_reconciled_at")
    assert_no_difference([ "EnterpriseCohortGrant.count", "CohortMembership.count" ]) do
      assert_raises(Enterprise::Client::Unavailable) { Enterprise::Reconciliation.call(@organization, client: @client) }
    end
    assert_equal before, @organization.reload.attributes.slice("directory_id", "directory_state", "last_reconciled_at")
    assert_equal "active", @membership.reload.status
    assert_equal "active", @membership.enterprise_directory_users.sole.state
  end

  private

  def user(role = "participant")
    key = SecureRandom.hex(6)
    User.create!(clerk_id: "test_#{key}", email: "#{key}@test.local", role: role)
  end
  def provider_membership
    { "id" => "om_bank", "organization_id" => "org_bank", "user_id" => "user_participant", "status" => "active", "updated_at" => "2026-10-07T20:00:00Z", "role" => { "slug" => "admin" } }
  end
  def directory_user
    { "id" => "directory_user_person", "directory_id" => "directory_bank", "organization_id" => "org_bank", "email" => "user_participant@bank.test", "state" => "active", "updated_at" => "2026-10-07T20:00:00Z" }
  end
  def group
    { "id" => "directory_group_participants", "directory_id" => "directory_bank", "organization_id" => "org_bank" }
  end
  def claims
    { "sub" => "user_participant", "org_id" => "org_bank", "sid" => "session_valid" }
  end
  def create_event(id, type, payload)
    EnterpriseSyncEvent.create!(workos_event_id: id, event_type: type, payload: payload, occurred_at: Time.iso8601("2026-10-07T20:00:00Z"))
  end
end
