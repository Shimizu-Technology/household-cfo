require "test_helper"
require "tmpdir"
require Rails.root.join("lib/scorecard/runner")

class ApiV1LocalStackReplayTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(clerk_id: "talun-replay-#{SecureRandom.hex(6)}", email: "talun-replay@example.invalid", role: "participant", invitation_status: "accepted")
    @household = Household.create!(created_by_user: @user, name: "Talun replay household")
    @household.household_memberships.create!(user: @user, role: "owner")
  end

  test "a real PDF upload replays through extraction and source review with no provider connection" do
    replay_environment do
      path = Rails.root.join("test/fixtures/files/documents/talun-year/checking-2026-01.pdf")
      Scorecard::Offline.call do
        perform_enqueued_jobs(only: FinancialDocumentExtractionJob) do
          post "/api/v1/document_imports", params: { file: Rack::Test::UploadedFile.new(path, "application/pdf"), document_kind: "statement" }, headers: headers
        end
      end
      assert_response :created, response.body
      document = @household.financial_document_imports.sole
      assert_equal "needs_review", document.reload.status, document.extraction_error
      assert_equal true, document.metadata["local_stack_replay"]
      assert_equal "recorded", document.attempts.order(:id).last.provider
      assert_equal "checking-2026-01.pdf", document.metadata["recorded_fixture"]
      revision = document.financial_extraction_revisions.order(:id).last
      assert revision.financial_source_events.exists?
      assert_nil SourceReviewHead.find_by(financial_source_event: revision.financial_source_events.first)&.approved_version_id
      get "/api/v1/document_imports/#{document.id}/source_review", params: { revision_id: revision.id }, headers: headers
      assert_response :success, response.body
      assert response.parsed_body.dig("source_review", "participant_review", "plan", "total").positive?
    end
  end

  test "an unrecorded upload fails plainly instead of calling a provider or accepting native CSV" do
    replay_environment do
      Tempfile.create([ "talun-invented", ".csv" ]) do |file|
        file.write("Date,Description,Amount\n2026-01-01,Talun Invented Store,-12.00\n")
        file.flush
        Scorecard::Offline.call do
          perform_enqueued_jobs(only: FinancialDocumentExtractionJob) do
            post "/api/v1/document_imports", params: { file: Rack::Test::UploadedFile.new(file.path, "text/csv"), document_kind: "statement" }, headers: headers
          end
        end
      end
      assert_response :created, response.body
      document = @household.financial_document_imports.sole.reload
      assert_equal "failed", document.status
      assert_equal FinancialDocuments::LocalStackReplayExtractor::NO_RECORDING, document.extraction_error
      assert_empty document.financial_extraction_revisions
    end
  end

  private

  def headers = { "Authorization" => "Bearer test_token_#{@user.id}", "Idempotency-Key" => SecureRandom.uuid }

  def replay_environment
    names = %w[LOCAL_STACK_REPLAY HCFO_LOCAL_STACK OPENROUTER_API_KEY STORAGE_BACKEND LOCAL_STORAGE_ROOT]
    previous = ENV.to_h.slice(*names)
    Dir.mktmpdir("talun-local-replay") do |storage|
      ENV.update("LOCAL_STACK_REPLAY" => "1", "HCFO_LOCAL_STACK" => "1", "OPENROUTER_API_KEY" => "", "STORAGE_BACKEND" => "local", "LOCAL_STORAGE_ROOT" => storage)
      yield
    end
  ensure
    names.each { |key| previous.key?(key) ? ENV[key] = previous[key] : ENV.delete(key) }
  end
end
