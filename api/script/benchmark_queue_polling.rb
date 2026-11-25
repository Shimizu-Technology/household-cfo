# Run with ruby (not rails runner): validate the dedicated local DB before boot.
require "uri"
require "json"
require "securerandom"
require "timeout"

database = "vera_polling_bench_20261119"
local_hosts = %w[localhost 127.0.0.1 ::1]
url = URI(ENV.fetch("DATABASE_URL"))
abort "Use dedicated local #{database} DB only" unless
  %w[postgres postgresql].include?(url.scheme) && local_hosts.include?(url.hostname) &&
    url.port == 5432 && url.path == "/#{database}" && ENV["RAILS_ENV"] == "test"
abort "Database routing overrides are forbidden" if url.query || ENV.key?("PGHOSTADDR") || ENV.key?("PGSERVICE")

require_relative "../config/environment"
connection = SolidQueue::Job.connection
resolved_host = connection.raw_connection.host
identity = connection.select_one("SELECT current_database() AS database, host(inet_server_addr()) AS address, inet_server_port() AS port")
local_endpoint = (%w[127.0.0.1 ::1].include?(identity["address"]) && identity["port"] == 5432) ||
  (identity["address"].nil? && resolved_host.start_with?("/"))
abort "Database connection mismatch" unless identity["database"] == database && local_endpoint &&
  (local_hosts.include?(resolved_host) || resolved_host.start_with?("/")) &&
  SolidQueue::Job.connection_pool == ActiveRecord::Base.connection_pool

class PollingBenchmarkJob < ActiveJob::Base
  self.queue_adapter = :solid_queue
  queue_as :polling_benchmark
  RESULTS = Queue.new

  def perform(enqueued, sample, invocation_id)
    RESULTS << { sample: sample, invocation_id: invocation_id, job_id: job_id, attempt: executions, milliseconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - enqueued) * 1000 }
  end
end

class PollingBenchmarkRetryJob < PollingBenchmarkJob
  retry_on RuntimeError, wait: 1.second, attempts: 2

  def perform(enqueued, sample, invocation_id)
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
invocation_id = SecureRandom.uuid
read_result = ->(expected_samples) do
  result = PollingBenchmarkJob::RESULTS.pop
  unless result[:invocation_id] == invocation_id && expected_samples.delete(result[:job_id]) == result[:sample]
    raise "Unexpected benchmark job result: #{result.inspect}"
  end
  result
end
await_result = ->(job, sample) do
  Timeout.timeout(5) { read_result.call({ job.job_id => sample }) }
end

# Cascading foreign keys remove execution rows for unfinished jobs from interrupted runs.
SolidQueue::Job.where(queue_name: "polling_benchmark", class_name: [ PollingBenchmarkJob.name, PollingBenchmarkRetryJob.name ], finished_at: nil).delete_all
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
    job = PollingBenchmarkJob.perform_later(clock.call, i, invocation_id)
    results << await_result.call(job, i)
  end
  scheduled_at = clock.call + 1
  job = PollingBenchmarkJob.set(wait: 1.second).perform_later(scheduled_at, "scheduled", invocation_id)
  scheduled = await_result.call(job, "scheduled")
  started = clock.call
  burst_jobs = Array.new(30) do |i|
    sample = "burst_#{i}"
    [ PollingBenchmarkJob.perform_later(started, sample, invocation_id), sample ]
  end
  expected_samples = burst_jobs.to_h { |job, sample| [ job.job_id, sample ] }
  burst_ids = burst_jobs.map { |job, _sample| job.provider_job_id }
  Timeout.timeout(10) do
    burst_jobs.size.times { read_result.call(expected_samples) }
    SolidQueue::Job.uncached do
      sleep 0.005 until SolidQueue::Job.finished.where(id: burst_ids).count == burst_jobs.size
    end
  end
  burst_ms = (clock.call - started) * 1000
  job = PollingBenchmarkRetryJob.perform_later(clock.call, "retry", invocation_id)
  retried = await_result.call(job, "retry")
  raise "Retry did not complete" unless retried[:attempt] == 2
  worker.stop
  job = PollingBenchmarkJob.perform_later(clock.call, "restart", invocation_id)
  worker = SolidQueue::Worker.new(queues: "*", threads: 3, polling_interval: interval)
  worker.start
  restarted = await_result.call(job, "restart")
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
