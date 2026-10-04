require "test_helper"

class FinancialDocumentSourceCleanupConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "cleanup retry and import removal use a consistent lock order" do
    suffix = SecureRandom.hex(6)
    user = User.create!(clerk_id: "cleanup-race-#{suffix}", email: "cleanup-race-#{suffix}@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Cleanup race QA")
    document = household.financial_document_imports.create!(uploaded_by_user: user,
      document_kind: "statement", status: "source_deleted", filename: "fictional.pdf",
      content_type: "application/pdf", byte_size: 32, s3_key: "qa/race/#{suffix}.pdf", source_deleted_at: Time.current)
    cleanup = FinancialDocumentSourceCleanup.request!(document, user: user)
    worker = nil
    backend_ids = Queue.new
    singleton = class << S3Service; self; end
    original = singleton.instance_method(:delete)
    singleton.define_method(:delete) { |_| true }

    document.with_lock do
      worker = Thread.new do
        Thread.current.report_on_exception = false
        ApplicationRecord.connection_pool.with_connection do |connection|
          backend_ids << connection.raw_connection.backend_pid
          FinancialDocumentSourceCleanupJob.perform_now(cleanup.id)
        end
      end
      backend_id = Timeout.timeout(5) { backend_ids.pop }
      Timeout.timeout(5) do
        loop do
          ApplicationRecord.connection.execute("SELECT pg_stat_clear_snapshot()")
          waiting = ApplicationRecord.connection.select_value("SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(backend_id)}")
          break if waiting == "Lock"
          raise "cleanup worker ended before lock contention" unless worker.alive?

          sleep 0.01
        end
      end
      document.destroy!
    end

    assert worker.join(5), "cleanup must finish after removal releases its import lock"
    worker.value
    assert_not FinancialDocumentImport.exists?(document.id)
    assert_equal "completed", cleanup.reload.status
    assert_nil cleanup.financial_document_import_id
    assert_nil cleanup.s3_key
  ensure
    worker&.kill if worker&.alive?
    worker&.join
    singleton&.send(:remove_method, :delete)
    singleton&.define_method(:delete, original) if original
    cleanup&.destroy!
    household&.destroy!
    user&.destroy!
  end
end
