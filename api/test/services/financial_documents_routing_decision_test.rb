require "test_helper"

class FinancialDocumentsRoutingDecisionTest < ActiveSupport::TestCase
  setup do
    user = User.create!(clerk_id: "routing-user", email: "routing@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Routing Household")
    household.household_memberships.create!(user: user, role: "owner")
    @document_import = household.financial_document_imports.build(
      uploaded_by_user: user,
      document_kind: "receipt",
      status: "uploaded",
      filename: "phone-upload.png",
      content_type: "image/png",
      byte_size: 100
    )
  end

  test "participant chat context wins and a conflicting detection requires confirmation" do
    @document_import.metadata = {
      "upload_origin" => "mia",
      "upload_context" => "This is my June bank statement. Please review every transaction.",
      "declared_document_kind" => "statement"
    }

    result = FinancialDocuments::RoutingDecision.new(@document_import, detected_kind: "receipt").call

    assert_equal "statement", result.resolved_kind
    assert_equal "participant_context", result.source
    assert_equal "transaction_review", result.destination
    assert result.conflict
    assert result.requires_confirmation
  end

  test "content detection routes an undescribed phone upload" do
    @document_import.metadata = {
      "upload_origin" => "mia",
      "declared_document_kind" => "receipt"
    }

    result = FinancialDocuments::RoutingDecision.new(@document_import, detected_kind: "pay_stub").call

    assert_equal "pay_stub", result.resolved_kind
    assert_equal "mia_detection", result.source
    assert_equal "household_setup_review", result.destination
    assert_not result.conflict
  end

  test "an explicit Mia upload selection remains authoritative with a generic message" do
    @document_import.document_kind = "pay_stub"
    @document_import.metadata = {
      "upload_origin" => "mia",
      "upload_context" => "Please review this upload.",
      "declared_document_kind" => "pay_stub",
      "document_kind_explicit" => true
    }

    result = FinancialDocuments::RoutingDecision.new(@document_import, detected_kind: "statement").call

    assert_equal "pay_stub", result.resolved_kind
    assert_equal "participant_selection", result.source
    assert_equal "mia_detection", result.conflict_reason
    assert result.requires_confirmation
  end

  test "message context wins but conflicts with a different explicit selection" do
    @document_import.document_kind = "pay_stub"
    @document_import.metadata = {
      "upload_origin" => "mia",
      "upload_context" => "This is my June bank statement.",
      "declared_document_kind" => "pay_stub",
      "document_kind_explicit" => true
    }

    result = FinancialDocuments::RoutingDecision.new(@document_import, detected_kind: "statement").call

    assert_equal "statement", result.resolved_kind
    assert_equal "participant_context", result.source
    assert_equal "participant_signals", result.conflict_reason
    assert result.requires_confirmation
  end

  test "invalid legacy kinds fall back to private document review" do
    @document_import.document_kind = nil
    @document_import.metadata = {}

    result = FinancialDocuments::RoutingDecision.new(@document_import, detected_kind: nil).call

    assert_equal "other", result.resolved_kind
    assert_equal "private_document_review", result.destination
    assert_not result.conflict
  end

  test "profile selection remains authoritative" do
    @document_import.metadata = {
      "upload_origin" => "profile",
      "declared_document_kind" => "spreadsheet"
    }
    @document_import.document_kind = "spreadsheet"

    result = FinancialDocuments::RoutingDecision.new(@document_import, detected_kind: "other").call

    assert_equal "spreadsheet", result.resolved_kind
    assert_equal "participant_selection", result.source
    assert_not result.conflict
  end
end
