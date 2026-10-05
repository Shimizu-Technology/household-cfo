require "test_helper"
require_relative "../support/savings_challenge_test_support"

class FinancialDocumentExtractionRecoveryJobTest < ActiveJob::TestCase
  include SavingsChallengeTestSupport

  WorkerKilled = Class.new(Exception)

  setup do
    @user = User.create!(clerk_id: "dispatch-qa", email: "dispatch-qa@example.com", role: "participant", invitation_status: "accepted")
    @household = Household.create!(created_by_user: @user, name: "Synthetic dispatch QA")
    @import = create_import
  end

  test "primary source registration and dispatch intent roll back together" do
    assert_no_difference("FinancialDocumentExtractionDispatch.count") do
      FinancialDocumentImport.transaction do
        @import.update!(s3_key: "qa/replacement.pdf")
        FinancialDocumentExtractionDispatch.request!(@import)
        raise ActiveRecord::Rollback
      end
    end
    assert_equal "qa/dispatch.pdf", @import.reload.s3_key
  end

  test "commit before queue admission survives a stopped request and repeated sweeps" do
    dispatch = FinancialDocumentExtractionDispatch.request!(@import)
    assert_enqueued_with(job: FinancialDocumentExtractionJob, args: [ @import.id, dispatch.id, 1 ]) do
      FinancialDocumentExtractionRecoveryJob.perform_now
    end
    assert_no_enqueued_jobs do
      FinancialDocumentExtractionRecoveryJob.perform_now
    end
    with_extractor do
      2.times { FinancialDocumentExtractionJob.perform_now(@import.id, dispatch.id, 1) }
    end
    assert_equal 1, @import.attempts.count
    assert_equal "completed", dispatch.reload.status
    assert_equal "applied", @import.reload.status
  end

  test "queue rejection and exceptions keep the committed intent with bounded backoff" do
    dispatch = FinancialDocumentExtractionDispatch.request!(@import)
    [ false, ->(*) { raise ActiveJob::EnqueueError, "secret filename and provider body" } ].each do |admission|
      with_singleton_stub(FinancialDocumentExtractionJob, :perform_later, admission) { assert_not dispatch.enqueue_retry }
      assert_equal "pending", dispatch.reload.status
      assert_operator dispatch.next_attempt_at, :>, Time.current
      assert_equal "uploaded", @import.reload.status
      assert_empty @import.attempts
      travel_to(dispatch.next_attempt_at + 1.second)
    end
    assert_enqueued_with(job: FinancialDocumentExtractionJob, args: [ @import.id, dispatch.id, 1 ]) do
      dispatch.enqueue_retry
    end
  ensure
    travel_back
  end

  test "admission response failure cannot reset a worker that already completed" do
    dispatch = FinancialDocumentExtractionDispatch.request!(@import)
    admission = lambda do |*args|
      FinancialDocumentExtractionJob.perform_now(*args)
      raise ActiveJob::EnqueueError, "uncertain admission"
    end
    with_extractor do
      with_singleton_stub(FinancialDocumentExtractionJob, :perform_later, admission) { dispatch.enqueue_retry }
    end
    assert_equal "completed", dispatch.reload.status
    assert_equal 1, @import.attempts.count
    assert_equal "applied", @import.reload.status
  end

  test "lost admitted job is redispatched after its lease expires" do
    dispatch = FinancialDocumentExtractionDispatch.request!(@import)
    dispatch.enqueue_retry
    travel_to dispatch.reload.lease_expires_at + 1.second do
      assert_enqueued_with(job: FinancialDocumentExtractionJob, args: [ @import.id, dispatch.id, 1 ]) do
        FinancialDocumentExtractionRecoveryJob.perform_now
      end
      with_extractor { FinancialDocumentExtractionJob.perform_now(@import.id, dispatch.id, 1) }
    end
    assert_equal 2, dispatch.reload.enqueue_attempts
    assert_equal "completed", dispatch.status
    assert_equal 1, @import.attempts.count
  end

  test "killed provider attempt is recovered without a second surviving job" do
    dispatch = FinancialDocumentExtractionDispatch.request!(@import)
    assert_raises(WorkerKilled) do
      with_extractor(-> { raise WorkerKilled }) { FinancialDocumentExtractionJob.perform_now(@import.id, dispatch.id, 1) }
    end
    old_attempt = @import.attempts.sole
    assert_equal "processing", @import.reload.status
    assert_equal "processing", dispatch.reload.status
    travel_to dispatch.lease_expires_at + 1.second do
      assert_enqueued_with(job: FinancialDocumentExtractionJob, args: [ @import.id, dispatch.id, 1 ]) do
        FinancialDocumentExtractionRecoveryJob.perform_now
      end
      with_extractor { FinancialDocumentExtractionJob.perform_now(@import.id, dispatch.id, 1) }
    end
    assert_equal "failed", old_attempt.reload.status
    assert_equal true, old_attempt.metadata["stalled"]
    assert_equal "succeeded", @import.attempts.order(:id).last.status
    assert_equal "completed", dispatch.reload.status
  end

  test "superseded generation cannot publish late results or reset the new dispatch" do
    dispatch = FinancialDocumentExtractionDispatch.request!(@import)
    before_return = lambda do
      @import.reload.update!(status: "uploaded")
      FinancialDocumentExtractionDispatch.request!(@import, restart: true)
    end
    with_extractor(before_return) { FinancialDocumentExtractionJob.perform_now(@import.id, dispatch.id, 1) }
    assert_equal "uploaded", @import.reload.status
    assert_empty @import.financial_extraction_revisions
    assert_equal "failed", @import.attempts.sole.status
    assert_equal true, @import.attempts.sole.metadata["superseded"]
    assert_equal 2, dispatch.reload.generation
    assert_equal "pending", dispatch.status
    assert_no_difference("FinancialDocumentImportAttempt.count") do
      with_extractor { FinancialDocumentExtractionJob.perform_now(@import.id, dispatch.id, 1) }
    end
    with_extractor { FinancialDocumentExtractionJob.perform_now(@import.id, dispatch.id, 2) }
    assert_equal 1, @import.financial_extraction_revisions.count
    assert_equal "completed", dispatch.reload.status
  end

  test "deleted source during provider work prevents financial publication" do
    dispatch = FinancialDocumentExtractionDispatch.request!(@import)
    before_return = -> { @import.reload.update!(status: "source_deleted", source_deleted_at: Time.current) }
    with_extractor(before_return) { FinancialDocumentExtractionJob.perform_now(@import.id, dispatch.id, 1) }
    assert_empty @import.financial_extraction_revisions
    assert_equal "source_deleted", @import.reload.status
    assert_no_enqueued_jobs { FinancialDocumentExtractionRecoveryJob.perform_now }
    assert_equal "cancelled", dispatch.reload.status
    assert_equal "source_unavailable", dispatch.error_code
  end

  test "unavailable local source never starts provider work" do
    dispatch = FinancialDocumentExtractionDispatch.request!(@import)
    @import.update!(status: "source_deleted", source_deleted_at: Time.current)
    with_singleton_stub(FinancialDocuments::Extractor, :new, -> { flunk "provider must not start" }) do
      FinancialDocumentExtractionRecoveryJob.perform_now
      FinancialDocumentExtractionJob.perform_now(@import.id, dispatch.id, 1)
    end
    assert_equal "cancelled", dispatch.reload.status
    assert_empty @import.attempts
  end

  test "worker preflight cancellation is immediately visible when a source lease is expired" do
    use = create_source_use
    dispatch = FinancialDocumentExtractionDispatch.request!(@import)
    dispatch.enqueue_retry
    use.update!(expires_at: 1.second.ago)
    with_singleton_stub(FinancialDocuments::Extractor, :new, -> { flunk "provider must not start" }) do
      FinancialDocumentExtractionJob.perform_now(@import.id, dispatch.id, 1)
    end
    assert_equal "failed", @import.reload.status
    assert_equal "cancelled", dispatch.reload.status
    assert_empty @import.attempts
    assert_nil @import.source_deleted_at
  end

  test "provider exception is terminal until manual retry and does not leak its message" do
    dispatch = FinancialDocumentExtractionDispatch.request!(@import)
    log = StringIO.new
    with_singleton_stub(Rails, :logger, ActiveSupport::Logger.new(log)) do
      with_extractor(-> { raise "raw private merchant and provider payload" }) do
        FinancialDocumentExtractionJob.perform_now(@import.id, dispatch.id, 1)
      end
    end
    assert_equal "failed", @import.reload.status
    assert_equal "completed", dispatch.reload.status
    refute_includes log.string, "raw private"
    refute_includes @import.extraction_error, "raw private"
    refute_includes @import.attempts.sole.error, "raw private"
    assert @import.source_available?, "a network/provider failure is not evidence of deleted source"
    assert_no_enqueued_jobs { FinancialDocumentExtractionRecoveryJob.perform_now }
    @import.update!(status: "uploaded")
    FinancialDocumentExtractionDispatch.request!(@import, restart: true)
    assert_equal 2, dispatch.reload.generation
    with_extractor { FinancialDocumentExtractionJob.perform_now(@import.id, dispatch.id, 2) }
    assert_equal "applied", @import.reload.status
  end

  test "bounded legacy backfill advances past queue failures and excludes completed imports" do
    104.times { |index| create_import("qa/dispatch-#{index}.pdf") }
    completed = create_import("qa/completed.pdf")
    completed.update!(status: "needs_review")
    with_singleton_stub(FinancialDocumentExtractionJob, :perform_later, false) do
      FinancialDocumentExtractionRecoveryJob.perform_now
      assert_equal 100, FinancialDocumentExtractionDispatch.count
      FinancialDocumentExtractionRecoveryJob.perform_now
      assert_equal 105, FinancialDocumentExtractionDispatch.count
    end
    assert_nil completed.reload.extraction_dispatch
    assert_equal [ "pending" ], FinancialDocumentExtractionDispatch.distinct.pluck(:status)
  end

  test "expired source lease blocks queue admission and produces a visible failed import" do
    use = create_source_use
    use.update!(expires_at: 1.second.ago)
    dispatch = FinancialDocumentExtractionDispatch.request!(@import)
    assert_no_enqueued_jobs { FinancialDocumentExtractionRecoveryJob.perform_now }
    assert_equal "cancelled", dispatch.reload.status
    assert_equal "failed", @import.reload.status
    assert_match(/no longer available/, @import.extraction_error)
    assert_nil @import.source_deleted_at, "authorization expiry is not proof of physical deletion"
    assert_empty @import.attempts
  end

  test "source use revocation during provider work rejects results and preserves prior facts" do
    use = create_source_use
    @import.update!(extracted_summary: "Prior pending facts", document_date: Date.new(2026, 6, 1))
    dispatch = FinancialDocumentExtractionDispatch.request!(@import)
    with_extractor(-> { use.update!(revoked_at: Time.current) }) do
      FinancialDocumentExtractionJob.perform_now(@import.id, dispatch.id, 1)
    end
    assert_equal "failed", @import.reload.status
    assert_equal "Prior pending facts", @import.extracted_summary
    assert_equal Date.new(2026, 6, 1), @import.document_date
    assert_equal "cancelled", dispatch.reload.status
    assert_empty @import.financial_extraction_revisions
    assert_empty @import.transaction_drafts
    assert_equal true, @import.attempts.sole.metadata["superseded"]
    use.update!(revoked_at: nil)
    @import.update!(status: "uploaded")
    FinancialDocumentExtractionDispatch.request!(@import, restart: true)
    with_extractor { FinancialDocumentExtractionJob.perform_now(@import.id, dispatch.id, 2) }
    assert_equal "applied", @import.reload.status
  end

  test "source lease expiring during provider work rejects even successful output" do
    use = create_source_use
    dispatch = FinancialDocumentExtractionDispatch.request!(@import)
    with_extractor(-> { travel_to use.expires_at + 1.second }) do
      FinancialDocumentExtractionJob.perform_now(@import.id, dispatch.id, 1)
    end
    assert_equal "failed", @import.reload.status
    assert_equal "cancelled", dispatch.reload.status
    assert_empty @import.financial_extraction_revisions
    assert_equal true, @import.attempts.sole.metadata["superseded"]
  ensure
    travel_back
  end

  test "changed source cannot publish late data or poison the recovery batch" do
    dispatch = FinancialDocumentExtractionDispatch.request!(@import)
    with_extractor(-> { @import.reload.update!(s3_key: "qa/changed.pdf") }) do
      FinancialDocumentExtractionJob.perform_now(@import.id, dispatch.id, 1)
    end
    assert_equal "failed", @import.reload.status
    assert_equal "cancelled", dispatch.reload.status
    assert_equal "source_changed", dispatch.error_code
    assert_empty @import.financial_extraction_revisions
    next_import = create_import("qa/next.pdf")
    next_dispatch = FinancialDocumentExtractionDispatch.request!(next_import)
    assert_enqueued_with(job: FinancialDocumentExtractionJob, args: [ next_import.id, next_dispatch.id, 1 ]) do
      FinancialDocumentExtractionRecoveryJob.perform_now
    end
  end

  test "batch heartbeats keep a long extraction current and a stopped heartbeat remains recoverable" do
    dispatch = FinancialDocumentExtractionDispatch.request!(@import)
    extractor = Object.new
    extractor.define_singleton_method(:model) { "synthetic" }
    context = self
    extractor.define_singleton_method(:call) do |_import, &progress|
      4.times do
        context.travel(6.minutes)
        context.assert progress.call
        context.assert_no_enqueued_jobs { FinancialDocumentExtractionRecoveryJob.perform_now }
      end
      raise WorkerKilled
    end
    assert_raises(WorkerKilled) do
      with_singleton_stub(FinancialDocuments::Extractor, :new, ->(*) { extractor }) do
        FinancialDocumentExtractionJob.perform_now(@import.id, dispatch.id, 1)
      end
    end
    assert_equal 1, @import.attempts.count
    assert_equal "processing", dispatch.reload.status
    assert_operator @import.reload.updated_at, :>, 1.minute.ago
    travel_to dispatch.lease_expires_at + 1.second
    assert_enqueued_with(job: FinancialDocumentExtractionJob, args: [ @import.id, dispatch.id, 1 ]) do
      FinancialDocumentExtractionRecoveryJob.perform_now
    end
    with_extractor { FinancialDocumentExtractionJob.perform_now(@import.id, dispatch.id, 1) }
    assert_equal 2, @import.attempts.count
    assert_equal "completed", dispatch.reload.status
  ensure
    travel_back
  end

  test "a superseded worker heartbeat cannot renew the replacement generation" do
    dispatch = FinancialDocumentExtractionDispatch.request!(@import)
    extractor = Object.new
    extractor.define_singleton_method(:model) { "synthetic" }
    callback = lambda do |&progress|
      @import.reload.update!(status: "uploaded")
      FinancialDocumentExtractionDispatch.request!(@import, restart: true)
      assert_equal false, progress.call
      assert_nil dispatch.reload.lease_expires_at
      raise WorkerKilled
    end
    extractor.define_singleton_method(:call) { |_import, &progress| callback.call(&progress) }
    assert_raises(WorkerKilled) do
      with_singleton_stub(FinancialDocuments::Extractor, :new, ->(*) { extractor }) do
        FinancialDocumentExtractionJob.perform_now(@import.id, dispatch.id, 1)
      end
    end
    assert_equal 2, dispatch.reload.generation
    assert_equal "pending", dispatch.status
    assert_nil dispatch.lease_expires_at
  end

  test "a full batch of changed source intents is cancelled so later work advances" do
    documents = [ @import ] + 99.times.map { |index| create_import("qa/poison-#{index}.pdf") }
    documents.each do |document|
      FinancialDocumentExtractionDispatch.request!(document)
      document.update!(s3_key: "#{document.s3_key}.changed")
    end
    next_import = create_import("qa/next-valid.pdf")
    next_dispatch = FinancialDocumentExtractionDispatch.request!(next_import)
    assert_no_enqueued_jobs { FinancialDocumentExtractionRecoveryJob.perform_now }
    assert_equal 100, FinancialDocumentExtractionDispatch.where(status: "cancelled", error_code: "source_changed").count
    assert_enqueued_with(job: FinancialDocumentExtractionJob, args: [ next_import.id, next_dispatch.id, 1 ]) do
      FinancialDocumentExtractionRecoveryJob.perform_now
    end
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
    singleton.send(:remove_method, method_name)
    singleton.define_method(method_name, original)
  end

  def create_source_use
    @import.update!(status: "needs_review")
    setup_savings_context
    with_savings_runtime { savings_enroll }
    @household, @user = @savings_household, @savings_user
    @import = create_import("qa/leased.pdf")
    FinancialSourceUse.create!(household: @household, savings_enrollment: @savings_enrollment, participant_user_id: @user.id,
      financial_document_import: @import, expires_at: 1.hour.from_now, authorized_at: Time.current,
      disclosure_version: ChallengePrivacy::SourceRetention::DISCLOSURE_VERSION)
  end

  def create_import(key = "qa/dispatch.pdf")
    @household.financial_document_imports.create!(uploaded_by_user: @user, document_kind: "statement",
      status: "uploaded", filename: "fictional.pdf", content_type: "application/pdf", byte_size: 32, s3_key: key)
  end

  def with_extractor(before_return = nil)
    result = FinancialDocuments::Extractor::Result.new(success: true, error: nil, metadata: {}, data: {
      document_kind: "statement", summary: "Synthetic empty statement", confidence: "high", warnings: [], items: []
    })
    extractor = Object.new
    extractor.define_singleton_method(:model) { "synthetic" }
    extractor.define_singleton_method(:call) do |_import|
      before_return&.call
      result
    end
    with_singleton_stub(FinancialDocuments::Extractor, :new, ->(*) { extractor }) { yield }
  end
end
