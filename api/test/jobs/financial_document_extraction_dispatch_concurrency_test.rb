require "test_helper"
require_relative "../support/owned_test_database"

class FinancialDocumentExtractionDispatchConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "two concurrent admission attempts claim one primary dispatch lease" do
    OwnedTestDatabase.assert!(connection: ApplicationRecord.connection)
    suffix = SecureRandom.hex(6)
    user = User.create!(clerk_id: "dispatch-race-#{suffix}", email: "dispatch-race-#{suffix}@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Dispatch concurrency QA")
    document = household.financial_document_imports.create!(uploaded_by_user: user,
      document_kind: "statement", status: "uploaded", filename: "fictional.pdf", content_type: "application/pdf", byte_size: 1, s3_key: "qa/dispatch/#{suffix}.pdf")
    dispatch = FinancialDocumentExtractionDispatch.request!(document)
    ready = Queue.new
    start = Queue.new
    calls = Queue.new
    singleton = class << FinancialDocumentExtractionJob; self; end
    original = singleton.instance_method(:perform_later)
    singleton.define_method(:perform_later) { |*args| calls << args; Object.new }
    workers = 2.times.map do
      Thread.new do
        Thread.current.report_on_exception = false
        ApplicationRecord.connection_pool.with_connection do |connection|
          ready << connection.select_value("SELECT pg_backend_pid()")
          start.pop
          FinancialDocumentExtractionDispatch.find(dispatch.id).enqueue_retry
        end
      end
    end
    backend_ids = 2.times.map { Timeout.timeout(5) { ready.pop } }
    assert_equal 2, backend_ids.uniq.length, "separate PostgreSQL sessions exercise row locks"
    2.times { start << true }
    workers.each { |worker| assert worker.join(5), "admission must not deadlock"; worker.value }
    assert_equal 1, calls.size
    assert_equal [ document.id, dispatch.id, 1 ], calls.pop
    assert_equal "enqueued", dispatch.reload.status
    assert_equal 1, dispatch.enqueue_attempts
    assert_empty document.attempts
  ensure
    workers&.each { |worker| worker.kill if worker.alive?; worker.join }
    singleton&.send(:remove_method, :perform_later)
    singleton&.define_method(:perform_later, original) if original
    dispatch&.destroy!
    household&.destroy!
    user&.destroy!
  end
end
