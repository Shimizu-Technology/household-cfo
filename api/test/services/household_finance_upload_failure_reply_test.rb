require "test_helper"

class HouseholdFinanceUploadFailureReplyTest < ActiveSupport::TestCase
  setup do
    user = User.create!(clerk_id: "f5-#{SecureRandom.hex(5)}", email: "f5-#{SecureRandom.hex(5)}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(user).household
    @failed = @household.financial_document_imports.create!(uploaded_by_user: user, document_kind: "receipt", status: "failed", filename: "unreadable.jpg", content_type: "image/jpeg", byte_size: 3, s3_key: "fictional/f5.jpg", metadata: { extraction_failure_permanent: true })
  end

  test "permanent failure uses the same recovery words as the card" do
    assert_equal FinancialDocuments::Extractor::REJECTED_FILE_MESSAGE, answer([ @failed ])
  end

  test "temporary failure repeats the stored participant retry words" do
    @failed.update!(metadata: {}, extraction_error: FinancialDocuments::Extractor::TEMPORARY_FAILURE_MESSAGE)
    assert_equal FinancialDocuments::Extractor::TEMPORARY_FAILURE_MESSAGE, answer([ @failed ])
  end

  test "mixed files give a read result and explain the unreadable file" do
    good = @household.financial_document_imports.create!(uploaded_by_user: @failed.uploaded_by_user, document_kind: "receipt", status: "needs_review", filename: "readable.csv", content_type: "text/csv", byte_size: 4, s3_key: "fictional/f5.csv")
    good.transaction_drafts.create!(household: @household, merchant: "Fictional shop", total_amount_cents: 1200, occurred_on: Date.new(2026, 10, 1), source_type: "receipt", status: "pending")
    text = answer([ good, @failed ])
    assert_includes text, "$12"
    assert_includes text, "unreadable.jpg: #{FinancialDocuments::Extractor::REJECTED_FILE_MESSAGE}"
    assert_includes text, "waiting for you to approve"
  end

  def answer(documents)
    HouseholdFinance::AttachedDocumentQuestionAnswerer.new(@household, message: "What is the total?", document_imports: documents).call
  end
end
