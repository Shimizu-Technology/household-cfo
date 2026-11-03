# frozen_string_literal: true

# Development-only, offline benchmark. Each real extraction job is rolled back.
# Use an isolated test database. Provider responses and downloads are local
# fictional corpus fixtures; this measures local overhead, not network latency.
raise 'Use an isolated test database' unless Rails.env.test? && ActiveRecord::Base.connection_db_config.database.match?(/(?:_qa_|_benchmark)/)

require 'benchmark'
require 'json'
require 'net/http'
if ENV['STATEMENT_BENCHMARK_BASELINE_DIR']
  load File.join(ENV.fetch('STATEMENT_BENCHMARK_BASELINE_DIR'), 'baseline_native.rb')
  load File.join(ENV.fetch('STATEMENT_BENCHMARK_BASELINE_DIR'), 'baseline_extractor.rb')
end
module StatementBenchmarkTiming
  def self.measure(stage)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    parent = Thread.current[:statement_benchmark_stack]&.last
    frame = { child: 0.0 }
    (Thread.current[:statement_benchmark_stack] ||= []) << frame
    yield
  ensure
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    Thread.current[:statement_benchmark_stack].pop
    parent[:child] += elapsed if parent
    (Thread.current[:statement_benchmark_timings] ||= Hash.new(0.0))[stage] += elapsed - frame[:child]
  end
  def self.wrap(klass, method, stage)
    klass.prepend(Module.new do
      define_method(method) { |*args, **opts, &block| StatementBenchmarkTiming.measure(stage) { super(*args, **opts, &block) } }
    end)
  end
end
StatementBenchmarkTiming.wrap(S3Service.singleton_class, :download_to_io, 'download_read')
StatementBenchmarkTiming.wrap(FinancialDocuments::SourceSafety.singleton_class, :pdf_page_count!, 'source_safety')
%i[pdf_text_readable? pdf_text_pages].each { |m| StatementBenchmarkTiming.wrap(FinancialDocuments::SourceSafety.singleton_class, m, 'text_extraction') if FinancialDocuments::SourceSafety.respond_to?(m) }
StatementBenchmarkTiming.wrap(FinancialDocuments::Extractor, :native_statement_result, 'native_parse')
StatementBenchmarkTiming.wrap(FinancialDocuments::Extractor, :perform_openrouter_request, 'model_replay')
StatementBenchmarkTiming.wrap(FinancialDocuments::RoutingDecision, :call, 'routing')
StatementBenchmarkTiming.wrap(FinancialDocumentExtractionJob, :persist_success!, 'persistence')
root = Rails.root.join('test/fixtures/files/documents')
S3Service.define_singleton_method(:configured?) { true }
S3Service.define_singleton_method(:download_to_io) { |key, io| io.write(File.binread(root.join(key))); true }
FinancialDocuments::Extractor.prepend(Module.new do
  def initialize(**options)
    super(**options.merge(api_key: 'offline-fixture'))
  end
  def perform_openrouter_request(_payload)
    Thread.current[:statement_benchmark_calls] += 1
    raw = Thread.current[:statement_benchmark_responses].shift.fetch('response').deep_symbolize_keys
    FinancialDocuments::Extractor::Result.new(**raw)
  end
end)
# Instrument the replay override, too.
StatementBenchmarkTiming.wrap(FinancialDocuments::Extractor, :perform_openrouter_request, 'model_replay')
output = []
ARGV.each do |filename|
  3.times do |run|
    ActiveRecord::Base.transaction(requires_new: true) do
      user = User.create!(clerk_id: SecureRandom.uuid, email: "statement-benchmark-#{SecureRandom.hex(5)}@example.invalid", role: 'participant', invitation_status: 'accepted')
      household = HouseholdFinance::WorkspaceResolver.new(user).household
      doc = FinancialDocumentImport.create!(household: household, uploaded_by_user: user, document_kind: 'statement', filename: filename, content_type: 'application/pdf', s3_key: filename, status: 'uploaded')
      Thread.current[:statement_benchmark_timings] = Hash.new(0.0)
      Thread.current[:statement_benchmark_calls] = 0
      recording = root.join('recorded_responses', "#{filename}.json")
      Thread.current[:statement_benchmark_responses] = JSON.parse(recording.read).fetch('responses')
      wall = Benchmark.realtime { FinancialDocumentExtractionJob.perform_now(doc.id) }
      doc.reload
      raise "#{filename}: #{doc.status}: #{doc.extraction_error}" unless doc.status == 'needs_review'
      output << { filename: filename, run: run + 1, wall_seconds: wall, calls: Thread.current[:statement_benchmark_calls], events: FinancialSourceEvent.where(financial_extraction_revision_id: doc.financial_extraction_revisions.select(:id)).count, mode: doc.metadata['extraction_mode'], seconds: Thread.current[:statement_benchmark_timings] }
      raise ActiveRecord::Rollback
    end
  end
end
File.write(ENV.fetch('STATEMENT_BENCHMARK_OUTPUT'), JSON.pretty_generate(output))
puts JSON.pretty_generate(output)
