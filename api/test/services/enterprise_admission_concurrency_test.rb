require "test_helper"
require "timeout"
require_relative "../support/owned_test_database"

class EnterpriseAdmissionConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class SnapshotClient < Enterprise::Client
    attr_accessor :before_groups, :before_memberships, :fail_groups, :auth_method
    attr_reader :network_calls
    def initialize(organization)
      @org_id, @directory_id = organization.workos_organization_id, organization.directory_id
      @network_calls = Queue.new
      @auth_method = "sso"
    end
    def memberships(organization_id:, user_id:)
      network!(:memberships)
      before_memberships&.call
      [ { "id" => "om_#{user_id}", "user_id" => user_id, "organization_id" => @org_id, "status" => "active", "updated_at" => Time.current.iso8601 } ]
    end
    def sessions(subject)
      network!(:sessions)
      [ { "id" => "session_#{subject}", "user_id" => subject, "organization_id" => @org_id, "status" => "active", "auth_method" => auth_method } ]
    end
    def directory(_id)
      network!(:directory)
      { "id" => @directory_id, "organization_id" => @org_id, "state" => "linked" }
    end
    def profile(subject)
      network!(:profile)
      { "id" => subject, "email" => "#{subject}@admission.test", "email_verified" => true }
    end
    def directory_users(directory_id:, email:)
      network!(:directory_users)
      [ { "id" => "directory_user_#{email.split('@').first}", "directory_id" => directory_id, "organization_id" => @org_id, "email" => email, "state" => "active", "updated_at" => Time.current.iso8601 } ]
    end
    def directory_groups(directory_id:, user_id:)
      network!(:directory_groups)
      before_groups&.call
      raise Enterprise::Client::Unavailable, "Provider unavailable" if fail_groups
      [ { "id" => "directory_group_participants", "directory_id" => directory_id, "organization_id" => @org_id } ]
    end
    private
    def network!(operation)
      raise "Provider HTTP inside an open database transaction: #{operation}" if ApplicationRecord.connection.transaction_open?
      network_calls << operation
    end
  end

  setup do
    key = SecureRandom.hex(8)
    @admin = User.create!(clerk_id: "admin_#{key}", email: "#{key}@admission.test", role: "admin")
    @workspace = CoachWorkspaces::Provisioner.ensure_for!(@admin)
    @cohort = Cohort.create!(name: "Admission", coach_workspace: @workspace, created_by_user: @admin, status: "active")
    @organization = EnterpriseOrganization.create!(name: "Bank", coach_workspace: @workspace, workos_organization_id: "org_#{key}", directory_id: "directory_#{key}", directory_state: "linked", directory_provisioning_enabled: true)
    @mapping = @organization.enterprise_group_mappings.create!(workos_group_id: "directory_group_participants", cohort: @cohort)
    @subjects = [ "user_#{key}A", "user_#{key}B" ]
    @client = SnapshotClient.new(@organization)
  end

  teardown do
    OwnedTestDatabase.assert!(connection: ApplicationRecord.connection)
    memberships = EnterpriseMembership.where(enterprise_organization_id: @organization.id)
    directory_users = EnterpriseDirectoryUser.where(enterprise_organization_id: @organization.id)
    EnterpriseCohortGrant.where(enterprise_membership_id: memberships.select(:id)).delete_all
    CohortMembership.where(cohort_id: @cohort.id).delete_all
    EnterpriseDirectoryGroupMembership.where(enterprise_directory_user_id: directory_users.select(:id)).delete_all
    directory_users.delete_all
    memberships.delete_all
    EnterpriseGroupMapping.where(enterprise_organization_id: @organization.id).delete_all
    @organization.enterprise_audit_events.delete_all
    @organization.reload.destroy!
    CohortExperienceConfiguration.where(cohort_id: @cohort.id).delete_all
    @cohort.reload.destroy!
    ids = AuthenticationIdentity.where(provider: "workos", subject: @subjects).pluck(:user_id)
    AuthenticationIdentity.where(user_id: ids).delete_all
    User.where(id: ids).delete_all
    delete_empty_coach_workspaces_for_users(@admin.id)
    @admin.reload.destroy!
  end

  test "all provider reads and final session proof occur outside database transactions" do
    user = resolve(@subjects.first)
    assert_equal "participant", user.role
    assert_equal 1, user.cohort_memberships.count
    calls = []
    calls << @client.network_calls.pop until @client.network_calls.empty?
    assert_includes calls, :directory
    assert_equal 2, calls.count(:sessions), "Final authorization remains authoritative after materialization"
  end

  test "first sign-ins fetch concurrently without holding the organization row lock" do
    ready, release = Queue.new, Queue.new
    @client.before_memberships = -> { ready << true; Timeout.timeout(5) { release.pop } }
    threads = @subjects.map { |subject| start_resolve(subject) }
    Timeout.timeout(5) { 2.times { ready.pop } }
    @organization.with_lock("FOR UPDATE NOWAIT") { assert @organization.active? }
    @client.before_memberships = nil
    2.times { release << true }
    results = threads.map { |thread| await_result(thread) }
    assert results.all? { |value| value.is_a?(User) }, results.inspect
    assert_equal 2, AuthenticationIdentity.where(subject: @subjects).count
    assert_equal 2, CohortMembership.where(cohort: @cohort).count
  ensure
    4.times { release << true } if release
    threads&.each { |thread| thread.join(6) }
  end

  test "overlapping admissions for one subject never duplicate identity or enrollment" do
    ready, release = Queue.new, Queue.new
    @client.before_memberships = -> { ready << true; Timeout.timeout(5) { release.pop } }
    threads = 2.times.map { start_resolve(@subjects.first) }
    Timeout.timeout(5) { 2.times { ready.pop } }
    @client.before_memberships = nil
    2.times { release << true }
    results = threads.map { |thread| await_result(thread) }
    assert results.any? { |value| value.is_a?(User) }, results.inspect
    assert results.all? { |value| value.is_a?(User) || value.is_a?(Enterprise::Client::Unavailable) }, results.inspect
    assert_equal 1, AuthenticationIdentity.where(subject: @subjects.first).count
    assert_equal 1, CohortMembership.where(cohort: @cohort).count
  ensure
    4.times { release << true } if release
    threads&.each { |thread| thread.join(6) }
  end

  test "local revocation committed during snapshot fetch is never undone" do
    membership = seed_membership
    result = while_snapshot_pending { @organization.with_lock { membership.update!(locally_revoked: true) } }
    assert_kind_of EnterpriseAccess::Denied, result
    assert membership.reload.locally_revoked?
    assert_nil membership.user_id
  end

  test "newer provider deactivation supersedes the captured active membership" do
    membership = seed_membership
    result = while_snapshot_pending { @organization.with_lock { membership.update!(status: "inactive", provider_updated_at: Time.current) } }
    assert_kind_of Enterprise::Client::Unavailable, result
    assert_equal "inactive", membership.reload.status
    assert_nil membership.user_id
  end

  test "revoking a bound local account during snapshot fetch still denies admission" do
    membership = seed_membership
    user = User.create!(clerk_id: "original_#{@subjects.first}", email: profile(@subjects.first)["email"], role: "participant")
    user.authentication_identities.create!(provider: "workos", issuer: WorkosAuth.issuer, subject: @subjects.first)
    membership.update!(user: user)
    result = while_snapshot_pending { user.update!(invitation_status: "revoked") }
    assert_kind_of EnterpriseAccess::Denied, result
    assert user.reload.revoked?
    assert_empty CohortMembership.where(cohort: @cohort)
  end

  test "completed reconciliation supersedes snapshots captured before its commit" do
    result = while_snapshot_pending { @organization.update!(last_reconciled_at: Time.current) }
    assert_kind_of Enterprise::Client::Unavailable, result
    assert_empty @organization.enterprise_memberships
    assert_empty AuthenticationIdentity.where(subject: @subjects)
  end

  test "group removal committed during fetch cannot be reactivated by a stale snapshot" do
    membership = seed_membership
    Enterprise::Provisioner.refresh_directory_for!(@organization, membership, profile(@subjects.first), client: @client)
    edge = membership.enterprise_directory_users.sole.enterprise_directory_group_memberships.sole
    result = while_snapshot_pending { @organization.with_lock { edge.update!(active: false, provider_updated_at: Time.current) } }
    assert_kind_of EnterpriseAccess::Denied, result
    refute edge.reload.active?
    assert_nil membership.reload.user_id
    assert_empty CohortMembership.where(cohort: @cohort)
  end

  test "organization disablement and vendor provisioning policy are rechecked after fetch" do
    result = while_snapshot_pending { @organization.update!(directory_provisioning_enabled: false) }
    assert_kind_of EnterpriseAccess::Denied, result
    assert_empty @organization.enterprise_memberships
    @organization.update!(directory_provisioning_enabled: true)
    result = while_snapshot_pending { @organization.update!(active: false) }
    assert_kind_of EnterpriseAccess::Denied, result
    assert_empty @organization.enterprise_memberships
  end

  test "newly required SSO rejects a fetched password session before user creation" do
    @organization.update!(require_sso: false)
    @client.auth_method = "password"
    result = while_snapshot_pending { @organization.update!(require_sso: true) }
    assert_kind_of EnterpriseAccess::Denied, result
    assert_equal "enterprise_sso_required", result.code
    assert_empty @organization.enterprise_memberships
    assert_empty AuthenticationIdentity.where(subject: @subjects)
  end

  test "snapshot outage leaves no partial admission records" do
    @client.fail_groups = true
    assert_raises(Enterprise::Client::Unavailable) { resolve(@subjects.first) }
    assert_empty @organization.enterprise_memberships
    assert_empty @organization.enterprise_directory_users
    assert_empty AuthenticationIdentity.where(subject: @subjects)
  end

  private
  def profile(subject)
    { "id" => subject, "email" => "#{subject}@admission.test", "email_verified" => true }
  end
  def resolve(subject)
    claims = { "sub" => subject, "org_id" => @organization.workos_organization_id, "sid" => "session_#{subject}" }
    Enterprise::Admission.resolve!(subject: subject, claims: claims, profile: profile(subject), client: @client)
  end
  def seed_membership
    @organization.enterprise_memberships.create!(workos_user_id: @subjects.first, status: "active", provider_updated_at: 1.minute.ago)
  end
  def start_resolve(subject)
    Thread.new do
      ApplicationRecord.connection_pool.with_connection { resolve(subject) }
    rescue StandardError => error
      error
    end
  end
  def await_result(thread)
    thread.join(10)
    assert !thread.alive?, "Admission exceeded the bounded concurrency wait"
    thread.value
  end
  def while_snapshot_pending
    ready, release = Queue.new, Queue.new
    @client.before_groups = -> { ready << true; Timeout.timeout(5) { release.pop } }
    thread = start_resolve(@subjects.first)
    Timeout.timeout(5) { ready.pop }
    yield
    @client.before_groups = nil
    release << true
    await_result(thread)
  ensure
    release << true if release
    thread&.join(6)
  end
end
