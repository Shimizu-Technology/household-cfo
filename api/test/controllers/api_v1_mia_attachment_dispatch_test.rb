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
  test "a declarative receipt upload gets a factual three sentence reply with no model" do
    user = User.create!(email: "f4-receipt-#{SecureRandom.hex(6)}@example.test", clerk_id: "test_#{SecureRandom.hex(6)}", role: "participant", invitation_status: "accepted")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    document = household.financial_document_imports.create!(uploaded_by_user: user, document_kind: "receipt", status: "needs_review", filename: "untrusted-name.jpg", content_type: "image/jpeg", byte_size: 100, s3_key: "fictional/receipt.jpg")
    document.transaction_drafts.create!(household: household, merchant: "Pay-Less Supermarkets", total_amount_cents: 6951, occurred_on: Date.new(2026, 11, 14), source_type: "receipt", status: "pending")
    post "/api/v1/mia/messages", params: { message: "Here is my grocery receipt from yesterday.", document_import_ids: [ document.id ] }, headers: { "Authorization" => "Bearer test_token_#{user.id}" }, as: :json
    assert_includes [ 200, 201 ], response.status, response.body
    reply = response.parsed_body.fetch("assistant_message").fetch("content")
    assert_includes reply, "Pay-Less Supermarkets for $69.51, on Nov 14, 2026"
    assert_includes reply, "card below is waiting for your tap"
    assert_not_includes reply, "Nothing from this message was saved"
    assert_not_includes reply, "structured values"
    assert_empty household.household_transactions
  end
end
