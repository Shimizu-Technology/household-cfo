require "test_helper"
require "timeout"

class EnterpriseSyncConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  self.fixture_paths = []

  class SnapshotClient
    attr_accessor :before_memberships, :before_events, :status
    attr_reader :event_calls

    def initialize(organization_id, status: "inactive")
      @organization_id = organization_id
      @status = status
      @event_calls = 0
    end

    def safe_id(value) = value
    def request(*) = { "id" => @organization_id }
    def list(*) = []

    def memberships(**)
      before_memberships&.call
      [ { "id" => "om_concurrency", "organization_id" => @organization_id, "user_id" => "user_concurrency", "status" => status } ]
    end

    def events(after: nil, **)
      @event_calls += 1
      before_events&.call
      { "data" => after == "event_complete" ? [] : [ { "id" => "event_complete", "event" => "organization_membership.updated",
        "created_at" => Time.current.iso8601(6), "data" => { "organization_id" => @organization_id } } ] }
    end
  end

  setup do
    key = SecureRandom.hex(6)
    @owner = User.create!(clerk_id: "owner_#{key}", email: "owner_#{key}@local.test", role: "admin")
    @workspace = CoachWorkspace.create!(created_by_user: @owner, name: "Sync concurrency", slug: "sync-#{key}")
    @organization = EnterpriseOrganization.create!(coach_workspace: @workspace, name: "Sync", workos_organization_id: "org_#{key}")
    @membership = @organization.enterprise_memberships.create!(workos_user_id: "user_concurrency", status: "active")
    @cursor = EnterpriseSyncCursor.create!(name: "workos", cursor: "event_previous")
    @event = EnterpriseSyncEvent.create!(workos_event_id: "event_concurrent", event_type: "organization_membership.updated",
      occurred_at: Time.current, payload: { "organization_id" => @organization.workos_organization_id })
    @client = SnapshotClient.new(@organization.workos_organization_id)
    @release = Queue.new
    @threads = []
  end

  teardown do
    @threads.length.times { @release << true }
    @threads.each { |thread| thread.join(10) }
    EnterpriseSyncEvent.where(workos_event_id: %w[event_concurrent event_complete]).delete_all
    EnterpriseSyncCursor.where(id: @cursor.id).delete_all
    EnterpriseAuditEvent.where(enterprise_organization: @organization).delete_all
    EnterpriseMembership.where(enterprise_organization: @organization).delete_all
    @organization.delete
    @workspace.delete
    @owner.delete
  end

  test "pollers exclude duplicate fetches while provider HTTP holds no cursor row transaction" do
    started = Queue.new
    @client.before_events = lambda do
      if @client.event_calls == 1
        started << ActiveRecord::Base.connection.open_transactions
        @release.pop
      end
    end
    worker { Enterprise::EventPoll.call(client: @client) }
    assert_equal 0, Timeout.timeout(5) { started.pop }
    # This lock used to wait for the entire network operation.
    Timeout.timeout(5) { @cursor.with_lock { assert_equal "event_previous", @cursor.cursor } }
    other = SnapshotClient.new(@organization.workos_organization_id)
    worker { Enterprise::EventPoll.call(client: other) }.value
    assert_equal 0, other.event_calls
    @release << true
    finish_threads
    assert_equal "event_complete", @cursor.reload.cursor
    assert_equal 1, EnterpriseSyncEvent.where(workos_event_id: "event_complete").count
  end

  test "parallel event claims do not hold inbox locks and an older active snapshot cannot undo deactivation" do
    started = Queue.new
    older = SnapshotClient.new(@organization.workos_organization_id, status: "active")
    older.before_memberships = lambda do
      started << ActiveRecord::Base.connection.open_transactions
      @release.pop
    end
    worker { Enterprise::EventProcessor.call(EnterpriseSyncEvent.find(@event.id), client: older) }
    assert_equal 0, Timeout.timeout(5) { started.pop }
    Timeout.timeout(5) { @event.with_lock { assert_nil @event.processed_at } }
    worker { Enterprise::EventProcessor.call(EnterpriseSyncEvent.find(@event.id), client: @client) }.value
    assert_equal "inactive", @membership.reload.status
    @release << true
    finish_threads
    assert_equal "inactive", @membership.reload.status
    assert @event.reload.processed_at
    assert_equal 2, @event.attempts
    assert_equal 1, @organization.enterprise_audit_events.where(action: "sync.processed").count
  end

  test "an older successful attempt cannot acknowledge over a newer failed attempt" do
    started = Queue.new
    older = SnapshotClient.new(@organization.workos_organization_id, status: "active")
    older.before_memberships = lambda do
      started << true
      @release.pop
    end
    worker { Enterprise::EventProcessor.call(EnterpriseSyncEvent.find(@event.id), client: older) }
    Timeout.timeout(5) { started.pop }
    @client.before_memberships = -> { raise Enterprise::Client::Unavailable, "Newer snapshot failed" }
    assert_raises(Enterprise::Client::Unavailable) { Enterprise::EventProcessor.call(EnterpriseSyncEvent.find(@event.id), client: @client) }
    @release << true
    finish_threads
    assert_nil @event.reload.processed_at
    assert_equal "Enterprise::Client::Unavailable", @event.last_error
    assert_equal 2, @event.attempts
    @client.before_memberships = nil
    Enterprise::EventProcessor.call(@event, client: @client)
    assert_equal "inactive", @membership.reload.status
    assert @event.reload.processed_at
    assert_nil @event.last_error
  end

  test "cursor recovery snapshots also run without a SQL transaction and keep durable failure metadata" do
    @cursor.update!(last_polled_at: 91.days.ago)
    @client.before_memberships = lambda do
      assert_equal 0, ActiveRecord::Base.connection.open_transactions
      raise Enterprise::Client::Unavailable, "Snapshot outage"
    end
    assert_raises(Enterprise::Client::Unavailable) { Enterprise::EventPoll.call(client: @client) }
    assert_equal "event_previous", @cursor.reload.cursor
    assert_equal "Enterprise::Client::Unavailable", @cursor.last_error
    assert_equal "Enterprise::Client::Unavailable", @organization.reload.last_sync_error
  end

  test "failed event snapshot durably records error after its claim transaction" do
    @client.before_memberships = lambda do
      assert_equal 0, ActiveRecord::Base.connection.open_transactions
      raise Enterprise::Client::Unavailable, "Provider outage"
    end
    assert_raises(Enterprise::Client::Unavailable) { Enterprise::EventProcessor.call(@event, client: @client) }
    assert_nil @event.reload.processed_at
    assert_equal 1, @event.attempts
    assert_equal "Enterprise::Client::Unavailable", @event.last_error
    assert_equal "Enterprise::Client::Unavailable", @organization.reload.last_sync_error
    assert_equal "active", @membership.reload.status
  end

  private

  def worker(&block)
    @threads << Thread.new { ActiveRecord::Base.connection_pool.with_connection { block.call } }
    @threads.last
  end

  def finish_threads
    Timeout.timeout(10) { @threads.each(&:value) }
  end
end
