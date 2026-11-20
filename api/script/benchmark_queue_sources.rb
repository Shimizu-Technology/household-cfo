require "uri"
require "json"
url = URI(ENV.fetch("DATABASE_URL"))
abort "Unsafe DB" unless ENV["RAILS_ENV"] == "test" && url.host == "localhost" && url.port == 5432 && url.path == "/vera_wakeup_bench_20261120" && ENV["DATABASE_TEST_NAME"] == url.path[1..]
require_relative "../config/environment"
abort "Resolved DB mismatch" unless ActiveRecord::Base.connection_db_config.database == url.path[1..]
ActiveRecord::Base.logger = nil
SolidQueue.logger = Logger.new(File::NULL)
ActiveJob::Base.logger = Logger.new(File::NULL)
results = {}
measure = ->(name, &action) do
  queries = []
  token = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
    payload = args.last
    queries << payload[:sql] unless payload[:cached] || payload[:name] == "SCHEMA"
  end
  begin
    action.call
  ensure
    ActiveSupport::Notifications.unsubscribe(token)
  end
  results[name] = { count: queries.size, sql: queries }
end
# Warm models; do not count schema discovery.
SolidQueue::Process.count
SolidQueue::RecurringExecution.count
measure.call("supervisor_prune_no_dead_processes") { SolidQueue::Process.prune }
process = SolidQueue::Process.register(kind: "Scheduler", name: "source-probe", pid: Process.pid, hostname: Socket.gethostname, metadata: {})
measure.call("scheduler_heartbeat") { process.heartbeat }
process.deregister
ENV.delete("WORKOS_SYNC_ENABLED")
ENV.delete("WORKOS_API_KEY")
measure.call("enterprise_disabled_business_body") { EnterpriseSyncJob.perform_now }
measure.call("enterprise_recurring_enqueue") do
  EnterpriseSyncJob.queue_adapter = :solid_queue
  task = SolidQueue::RecurringTask.new(key: "probe-enterprise", class_name: "EnterpriseSyncJob", schedule: "every 30 seconds")
  task.enqueue(at: Time.current)
end
# Enqueue only: there are no workers here, so no provider or recovery body runs.
ApplicationJob.queue_adapter = :solid_queue
SolidQueue::RecurringJob.queue_adapter = :solid_queue
Rails.application.config_for(:recurring, env: "production").each do |key, attributes|
  measure.call("recurring_enqueue_#{key}") do
    SolidQueue::RecurringTask.new(**attributes.except(:class).merge(class_name: attributes[:class]), key: key.to_s).enqueue(at: Time.current)
  end
end
puts JSON.pretty_generate(results)
