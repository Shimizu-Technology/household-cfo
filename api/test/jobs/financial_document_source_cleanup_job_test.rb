require "test_helper"

class FinancialDocumentSourceCleanupJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(clerk_id: "cleanup-user", email: "cleanup@example.com", role: "participant", invitation_status: "accepted")
    @household = Household.create!(created_by_user: @user, name: "Cleanup QA")
    @import = @household.financial_document_imports.create!(uploaded_by_user: @user,
      document_kind: "statement", status: "source_deleted", filename: "fictional.pdf",
      content_type: "application/pdf", byte_size: 32, s3_key: "qa/cleanup/source.pdf", source_deleted_at: Time.current)
    @cleanup = FinancialDocumentSourceCleanup.request!(@import, user: @user)
  end

  test "storage failure after import deletion retains a durable key and retries" do
    @import.destroy!
    with_singleton_stub(S3Service, :delete, false) { FinancialDocumentSourceCleanupJob.perform_now(@cleanup.id) }
    assert_equal "failed", @cleanup.reload.status
    assert_equal "qa/cleanup/source.pdf", @cleanup.s3_key
    assert_nil @cleanup.financial_document_import_id
    assert_equal "storage_unavailable", @cleanup.error_code
    assert_equal 1, @cleanup.attempts
    assert_enqueued_with(job: FinancialDocumentSourceCleanupJob, args: [ @cleanup.id ])

    travel_to @cleanup.next_attempt_at + 1.second do
      assert_enqueued_with(job: FinancialDocumentSourceCleanupJob, args: [ @cleanup.id ]) do
        FinancialDocumentSourceCleanupRecoveryJob.perform_now
      end
      with_singleton_stub(S3Service, :delete, true) { FinancialDocumentSourceCleanupJob.perform_now(@cleanup.id) }
    end
    assert_equal "completed", @cleanup.reload.status
    assert_nil @cleanup.s3_key
    assert_equal 2, @cleanup.attempts
  end

  test "queue failure cannot lose a storage cleanup request" do
    failing_queue = Object.new
    failing_queue.define_singleton_method(:perform_later) { |_| raise ActiveJob::EnqueueError, "unavailable" }
    with_singleton_stub(S3Service, :delete, false) do
      with_singleton_stub(FinancialDocumentSourceCleanupJob, :set, failing_queue) do
        FinancialDocumentSourceCleanupJob.perform_now(@cleanup.id)
      end
    end
    assert_equal "failed", @cleanup.reload.status
    assert @cleanup.s3_key.present?
    travel_to @cleanup.next_attempt_at + 1.second do
      assert_includes FinancialDocumentSourceCleanup.due, @cleanup
    end
  end

  test "active lease prevents duplicate delete and expired lease is recoverable" do
    plan = @cleanup.claim!
    assert plan
    assert_nil @cleanup.claim!
    with_singleton_stub(S3Service, :delete, ->(_) { flunk("active cleanup lease must not be stolen") }) do
      FinancialDocumentSourceCleanupJob.perform_now(@cleanup.id)
    end
    travel_to @cleanup.lease_expires_at + 1.second do
      assert_includes FinancialDocumentSourceCleanup.due, @cleanup
      with_singleton_stub(S3Service, :delete, true) { FinancialDocumentSourceCleanupJob.perform_now(@cleanup.id) }
    end
    assert_equal "completed", @cleanup.reload.status
    assert_equal 2, @cleanup.attempts
  end

  test "completed cleanup is idempotent and clears only the deleted source" do
    with_singleton_stub(S3Service, :delete, true) { FinancialDocumentSourceCleanupJob.perform_now(@cleanup.id) }
    assert_nil @import.reload.s3_key
    with_singleton_stub(S3Service, :delete, ->(_) { flunk("completed request must not delete again") }) do
      FinancialDocumentSourceCleanupJob.perform_now(@cleanup.id)
    end
    assert_equal 1, @cleanup.reload.attempts
  end

  test "successful cleanup never clears a replacement source" do
    @import.update!(s3_key: "qa/replacement.pdf", source_deleted_at: nil, status: "uploaded")
    with_singleton_stub(S3Service, :delete, true) { FinancialDocumentSourceCleanupJob.perform_now(@cleanup.id) }
    assert_equal "qa/replacement.pdf", @import.reload.s3_key
    assert @import.source_available?
  end

  test "repeated requests share the same persisted outbox entry" do
    assert_no_difference("FinancialDocumentSourceCleanup.count") do
      assert_equal @cleanup.id, FinancialDocumentSourceCleanup.request!(@import, user: @user).id
    end
  end

  test "partially applied sources remain in operational review counts" do
    @import.update!(status: "partially_applied")
    assert_includes @household.financial_document_imports.pending_review, @import
  end

  private

  def with_singleton_stub(target, method_name, replacement)
    singleton = class << target; self; end
    original = singleton.instance_method(method_name)
    singleton.define_method(method_name) do |*args, **kwargs, &block|
      replacement.respond_to?(:call) ? replacement.call(*args, **kwargs, &block) : replacement
    end
    yield
  ensure
    singleton.send(:remove_method, method_name) if singleton.method_defined?(method_name)
    singleton.define_method(method_name, original)
  end
end
