# Run with ruby (not rails runner): validate the dedicated local DB before boot.
require "uri"
require "json"
require "timeout"

url = URI(ENV.fetch("DATABASE_URL"))
abort "Use dedicated local vera_polling_bench_20261119 DB only" unless
  %w[postgres postgresql].include?(url.scheme) && url.host == "localhost" &&
    url.port == 5432 && url.path == "/vera_polling_bench_20261119" && ENV["RAILS_ENV"] == "test"
require_relative "../config/environment"
abort "Database configuration mismatch" unless ActiveRecord::Base.connection_db_config.database == url.path.delete_prefix("/")

class PollingBenchmarkJob < ActiveJob::Base
  self.queue_adapter = :solid_queue
  queue_as :polling_benchmark
  RESULTS = Queue.new

  def perform(enqueued, sample)
    RESULTS << { sample: sample, attempt: executions, milliseconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - enqueued) * 1000 }
  end
end

class PollingBenchmarkRetryJob < PollingBenchmarkJob
  retry_on RuntimeError, wait: 1.second, attempts: 2

  def perform(enqueued, sample)
    raise "Synthetic transient failure" if executions == 1
    super
  end
end

interval = ARGV.first ? Float(ARGV.first) : Rails.application.config_for(:queue).fetch(:workers).first.fetch(:polling_interval)
abort "Invalid interval" unless interval.positive? && interval <= 1
ActiveRecord::Base.logger = nil
SolidQueue.logger = Logger.new(File::NULL)
ActiveJob::Base.logger = Logger.new(File::NULL)
worker = SolidQueue::Worker.new(queues: "*", threads: 3, polling_interval: interval)
dispatcher = SolidQueue::Dispatcher.new(polling_interval: 1, batch_size: 500)
clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
user = User.find_or_create_by!(clerk_id: "polling_benchmark") do |record|
  record.email = "polling-benchmark@example.invalid"
  record.role = "participant"
  record.invitation_status = "accepted"
end
HouseholdFinance::WorkspaceResolver.new(user).household
request = -> do
  session = ActionDispatch::Integration::Session.new(Rails.application)
  started = clock.call
  session.get("/api/v1/workspace", headers: { "Authorization" => "Bearer test_token_#{user.id}" })
  raise "Workspace request failed: #{session.response.status}" unless session.response.status == 200 && session.response.parsed_body.key?("workspace")
  (clock.call - started) * 1000
end

begin
  request.call # warm code; measure requests on an already booted service
  worker.start
  dispatcher.start
  sleep 2 # exclude process registration and schema discovery
  queries = 0
  mutex = Mutex.new
  subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
    payload = args.last
    mutex.synchronize { queries += 1 } unless payload[:cached] || payload[:name] == "SCHEMA"
  end
  started = clock.call
  sleep 60
  elapsed = clock.call - started
  count = mutex.synchronize { queries }
  ActiveSupport::Notifications.unsubscribe(subscriber)
  request_queries = 0
  request_subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
    request_queries += 1 if Thread.current == Thread.main && !args.last[:cached] && args.last[:name] != "SCHEMA"
  end
  first_request = request.call
  ActiveSupport::Notifications.unsubscribe(request_subscriber)
  raise "Workspace benchmark did not access DB" unless request_queries.positive?
  results = []
  30.times do |i|
    sleep Random.new(i).rand(0.05..0.6) # sample varying phases of the idle poll
    PollingBenchmarkJob.perform_later(clock.call, i)
    result = Timeout.timeout(5) { PollingBenchmarkJob::RESULTS.pop }
    raise "Unexpected immediate job result" unless result[:sample] == i
    results << result
  end
  scheduled_at = clock.call + 1
  PollingBenchmarkJob.set(wait: 1.second).perform_later(scheduled_at, "scheduled")
  scheduled = Timeout.timeout(5) { PollingBenchmarkJob::RESULTS.pop }
  raise "Scheduled job did not complete" unless scheduled[:sample] == "scheduled"
  started = clock.call
  30.times { |i| PollingBenchmarkJob.perform_later(started, "burst_#{i}") }
  burst_results = Timeout.timeout(10) { Array.new(30) { PollingBenchmarkJob::RESULTS.pop } }
  raise "Duplicate or missing burst jobs" unless burst_results.map { |r| r[:sample] }.uniq.size == 30
  burst_ms = (clock.call - started) * 1000
  PollingBenchmarkRetryJob.perform_later(clock.call, "retry")
  retried = Timeout.timeout(5) { PollingBenchmarkJob::RESULTS.pop }
  raise "Retry did not complete" unless retried[:sample] == "retry" && retried[:attempt] == 2
  worker.stop
  PollingBenchmarkJob.perform_later(clock.call, "restart")
  worker = SolidQueue::Worker.new(queues: "*", threads: 3, polling_interval: interval)
  worker.start
  restarted = Timeout.timeout(5) { PollingBenchmarkJob::RESULTS.pop }
  raise "Restart did not recover persisted job" unless restarted[:sample] == "restart"
  values = results.map { |r| r[:milliseconds] }.sort
  puts JSON.pretty_generate(interval: interval, idle_seconds: elapsed, idle_sql_statements: count,
    idle_queries_per_minute: count * 60 / elapsed, first_workspace_request_after_idle_ms: first_request, workspace_sql_statements: request_queries,
    immediate_pickup_ms: { p50: values[14], p95: values[28], max: values.last, samples: values },
    scheduled_lateness_ms: scheduled[:milliseconds], burst_30_completion_ms: burst_ms,
    retry_completion_ms: retried[:milliseconds], restart_pickup_ms: restarted[:milliseconds])
ensure
  ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  worker.stop
  dispatcher.stop
end
