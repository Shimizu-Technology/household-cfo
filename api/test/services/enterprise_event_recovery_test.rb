require_relative "enterprise_provisioning_test"
require_relative "../support/workos_auth_test_support"

class EnterpriseEventRecoveryTest < ActiveSupport::TestCase
  include WorkosAuthTestSupport

  class RecoveryClient < EnterpriseProvisioningTest::FakeClient
    attr_accessor :reject_after, :empty_replay, :during_snapshot, :snapshot_failure, :event_rows
    attr_reader :event_queries
    def initialize
      super
      @event_queries = []
      @event_rows = []
    end
    def events(after: nil, range_start: nil)
      event_queries << { after: after, range_start: range_start }
      raise Enterprise::Client::CursorRejected, "Expired" if reject_after && after == reject_after
      return { "data" => [] } if empty_replay || after == event_rows.last&.fetch("id")
      { "data" => event_rows }
    end
    def memberships(**options)
      raise Enterprise::Client::Unavailable, "Snapshot failure" if snapshot_failure
      result = super
      during_snapshot&.call
      result
    end
  end

  setup do
    key = SecureRandom.hex(6)
    @admin = User.create!(clerk_id: "admin_#{key}", email: "admin_#{key}@local.test", role: "admin")
    @user = User.create!(clerk_id: "participant_#{key}", email: "person_#{key}@local.test")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(@admin)
    @organization = EnterpriseOrganization.create!(name: "Bank", workos_organization_id: "org_bank", coach_workspace: workspace)
    @membership = @organization.enterprise_memberships.create!(user: @user, workos_user_id: "user_participant", status: "active", it_admin: true)
    @cursor = EnterpriseSyncCursor.create!(name: "workos", cursor: "event_expired", last_polled_at: Time.current)
    @client = RecoveryClient.new
    @client.directory = nil
    @client.provider_memberships = [ { "id" => "om_bank", "user_id" => "user_participant", "organization_id" => "org_bank", "status" => "inactive", "updated_at" => 1.minute.ago.iso8601 } ]
    @client.reject_after = "event_expired"
  end

  test "rejected cursor reconciles deactivation before rebaselining an empty feed" do
    household = Household.create!(created_by_user: @user, name: "Retained")
    @client.empty_replay = true
    Enterprise::EventPoll.call(client: @client)
    assert_equal "inactive", @membership.reload.status
    refute @membership.it_admin?
    assert Household.exists?(household.id)
    assert @cursor.reload.cursor.start_with?(Enterprise::EventPoll::REPLAY_PREFIX)
    assert_nil @client.event_queries.last[:after]
    assert @client.event_queries.reverse.find { |query| query[:range_start] }[:range_start]
    assert_nil @cursor.last_error
  end

  test "deactivation during recovery remains in durable replay after snapshot" do
    @client.provider_memberships.first["status"] = "active"
    @client.during_snapshot = lambda do
      @client.event_rows = [ event("event_during_recovery") ]
    end
    Enterprise::EventPoll.call(client: @client)
    assert_equal "event_during_recovery", @cursor.reload.cursor
    inbox = EnterpriseSyncEvent.find_by!(workos_event_id: "event_during_recovery")
    @client.provider_memberships.first["status"] = "inactive"
    @client.during_snapshot = nil
    Enterprise::EventProcessor.call(inbox, client: @client)
    assert_equal "inactive", @membership.reload.status
    assert inbox.reload.processed_at
    assert Time.iso8601(@client.event_queries[1][:range_start]) <= inbox.occurred_at
  end

  test "worker restart with empty-feed timestamp checkpoint still captures later event" do
    @client.empty_replay = true
    Enterprise::EventPoll.call(client: @client)
    checkpoint = @cursor.reload.cursor
    @client.empty_replay = false
    @client.event_rows = [ event("event_after_restart") ]
    Enterprise::EventPoll.call(client: @client)
    assert_equal "event_after_restart", @cursor.reload.cursor
    assert_equal checkpoint.delete_prefix(Enterprise::EventPoll::REPLAY_PREFIX), @client.event_queries.reverse.find { |query| query[:range_start] }[:range_start]
    assert EnterpriseSyncEvent.exists?(workos_event_id: "event_after_restart")
  end

  test "incomplete authoritative snapshot never replaces cursor or local membership" do
    @client.snapshot_failure = true
    assert_raises(Enterprise::Client::Unavailable) { Enterprise::EventPoll.call(client: @client) }
    assert_equal "event_expired", @cursor.reload.cursor
    assert_equal "active", @membership.reload.status
    assert_nil @organization.reload.last_reconciled_at
    assert_equal "Enterprise::Client::Unavailable", @cursor.last_error
  end

  test "retention age triggers recovery before sending retired after cursor" do
    @cursor.update!(last_polled_at: 91.days.ago)
    @client.reject_after = nil
    @client.empty_replay = true
    Enterprise::EventPoll.call(client: @client)
    assert_equal "inactive", @membership.reload.status
    assert_nil @client.event_queries.first[:after]
    assert @client.event_queries.first[:range_start]
  end

  test "retired event checkpoint age triggers recovery even after successful empty polls" do
    EnterpriseSyncEvent.create!(workos_event_id: "event_expired", event_type: "organization_membership.updated", payload: {}, occurred_at: 91.days.ago, processed_at: 91.days.ago)
    @client.reject_after = nil
    @client.empty_replay = true
    Enterprise::EventPoll.call(client: @client)
    assert_equal "inactive", @membership.reload.status
    assert_nil @client.event_queries.first[:after]
  end

  test "old replay timestamp is renewed only after a successful authoritative snapshot" do
    @cursor.update!(cursor: "#{Enterprise::EventPoll::REPLAY_PREFIX}#{31.days.ago.iso8601}")
    @client.empty_replay = true
    Enterprise::EventPoll.call(client: @client)
    start = Time.iso8601(@cursor.reload.cursor.delete_prefix(Enterprise::EventPoll::REPLAY_PREFIX))
    assert_operator start, :>, 6.minutes.ago
    assert_equal "inactive", @membership.reload.status
  end

  test "polling outage does not prevent existing inbox processing or due reconciliation" do
    previous_key = ENV["WORKOS_API_KEY"]
    previous_flag = ENV["WORKOS_SYNC_ENABLED"]
    ENV["WORKOS_API_KEY"] = "test_key"
    ENV["WORKOS_SYNC_ENABLED"] = "true"
    queued = EnterpriseSyncEvent.create!(workos_event_id: "event_pending", event_type: "organization_membership.updated", payload: {}, occurred_at: Time.current)
    processed = []
    reconciled = []
    failure = ->(*) { raise Enterprise::Client::Unavailable, "Events outage" }
    stub_method(Enterprise::EventPoll, :call, failure) do
      stub_method(Enterprise::EventProcessor, :call, ->(event, **_options) { processed << event.id }) do
        stub_method(Enterprise::Reconciliation, :call, ->(organization, **_options) { reconciled << organization.id }) do
          assert_raises(Enterprise::Client::Unavailable) { EnterpriseSyncJob.new.perform }
        end
      end
    end
    assert_includes processed, queued.id
    assert_includes reconciled, @organization.id
  ensure
    ENV["WORKOS_API_KEY"] = previous_key
    ENV["WORKOS_SYNC_ENABLED"] = previous_flag
  end

  test "event pagination cycles preserve the previously committed checkpoint" do
    @client.reject_after = nil
    ids = %w[event_a event_b event_a]
    client = @client
    client.define_singleton_method(:events) do |**_options|
      { "data" => [ { "id" => ids.shift, "event" => "organization_membership.updated", "created_at" => Time.current.iso8601,
        "data" => { "organization_id" => "org_bank" } } ] }
    end
    assert_no_difference("EnterpriseSyncEvent.count") do
      assert_raises(Enterprise::Client::Unavailable) { Enterprise::EventPoll.call(client: client) }
    end
    assert_equal "event_expired", @cursor.reload.cursor
  end

  test "a malformed inbox page rolls back all inserts and the checkpoint together" do
    @client.reject_after = nil
    @client.event_rows = [ event("event_valid"), event("event_invalid").merge("event" => nil) ]
    assert_no_difference("EnterpriseSyncEvent.count") do
      assert_raises(ActiveRecord::RecordInvalid) { Enterprise::EventPoll.call(client: @client) }
    end
    assert_equal "event_expired", @cursor.reload.cursor
    assert_equal "ActiveRecord::RecordInvalid", @cursor.last_error
  end

  test "replay API outage never commits recovery checkpoint ahead of its inbox" do
    original = @client.method(:events)
    @client.define_singleton_method(:events) do |**options|
      raise Enterprise::Client::Unavailable, "Replay unavailable" if options[:range_start]
      original.call(**options)
    end
    assert_raises(Enterprise::Client::Unavailable) { Enterprise::EventPoll.call(client: @client) }
    assert_equal "event_expired", @cursor.reload.cursor
    assert_equal "inactive", @membership.reload.status
    assert @organization.reload.last_reconciled_at
    assert_empty EnterpriseSyncEvent.where(processed_at: nil)
  end

  test "failed tenant recovery continues later organizations and keeps the original cursor" do
    later = EnterpriseOrganization.create!(name: "Later", workos_organization_id: "org_later", coach_workspace: @organization.coach_workspace)
    reconciled = []
    failure = lambda do |organization, **_options|
      reconciled << organization.id
      raise EnterpriseAccess::Denied, "Tenant mismatch" if organization.id == @organization.id
    end
    stub_method(Enterprise::Reconciliation, :call, failure) do
      assert_raises(EnterpriseAccess::Denied) { Enterprise::EventPoll.call(client: @client) }
    end
    assert_equal [ @organization.id, later.id ], reconciled
    assert_equal "event_expired", @cursor.reload.cursor
    assert_equal "EnterpriseAccess::Denied", @cursor.last_error
  end

  test "hourly recovery isolates tenant errors and retains polling error priority" do
    later = EnterpriseOrganization.create!(name: "Later", workos_organization_id: "org_later", coach_workspace: @organization.coach_workspace)
    old_key, old_flag = ENV.values_at("WORKOS_API_KEY", "WORKOS_SYNC_ENABLED")
    ENV["WORKOS_API_KEY"] = "test_key"
    ENV["WORKOS_SYNC_ENABLED"] = "true"
    reconciled = []
    failure = lambda do |organization, **_options|
      reconciled << organization.id
      raise EnterpriseAccess::Denied, "Tenant mismatch" if organization.id == @organization.id
    end
    stub_method(Enterprise::EventPoll, :call, ->(*) { raise Enterprise::Client::Unavailable, "Poll outage" }) do
      stub_method(Enterprise::Reconciliation, :call, failure) do
        error = assert_raises(Enterprise::Client::Unavailable) { EnterpriseSyncJob.new.perform }
        assert_equal "Poll outage", error.message
      end
    end
    assert_equal [ @organization.id, later.id ], reconciled
    reconciled.clear
    stub_method(Enterprise::EventPoll, :call, ->(*) { }) do
      stub_method(Enterprise::Reconciliation, :call, failure) do
        assert_raises(EnterpriseAccess::Denied) { EnterpriseSyncJob.new.perform }
      end
    end
    assert_equal [ @organization.id, later.id ], reconciled
  ensure
    ENV["WORKOS_API_KEY"], ENV["WORKOS_SYNC_ENABLED"] = old_key, old_flag
  end

  private
  def event(id)
    { "id" => id, "event" => "organization_membership.updated", "created_at" => Time.current.iso8601(6),
      "data" => { "organization_id" => "org_bank", "user_id" => "user_participant", "status" => "inactive" } }
  end
end
