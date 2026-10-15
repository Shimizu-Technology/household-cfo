require "test_helper"

class ApiV1MiaAttachmentDispatchTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  test "an uploaded attachment is enqueued through its dispatch generation" do
    user = User.create!(email: "attach-#{SecureRandom.hex(6)}@example.test", clerk_id: "test_#{SecureRandom.hex(6)}", role: "participant", invitation_status: "accepted")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    document_import = FinancialDocumentImport.create!(household: household, uploaded_by_user: user, document_kind: "receipt",
      status: "uploaded", filename: "receipt.png", content_type: "image/png", byte_size: 100, s3_key: "household-cfo/test/receipt.png")

    post "/api/v1/mia/messages", params: { message: "Please review this receipt", document_import_ids: [ document_import.id ] },
      headers: { "Authorization" => "Bearer test_token_#{user.id}" }, as: :json

    assert_includes [ 200, 201, 202 ], response.status, response.body
    dispatch = FinancialDocumentExtractionDispatch.find_by!(financial_document_import_id: document_import.id)
    extraction_jobs = enqueued_jobs.select { |job| job[:job] == FinancialDocumentExtractionJob }
    assert_equal 1, extraction_jobs.size
    # A generation-bound job cannot later fail or complete a newer Reprocess generation.
    assert_equal [ document_import.id, dispatch.id, dispatch.generation ], extraction_jobs.sole[:args]
  end
end
