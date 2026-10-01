require "test_helper"

class HouseholdFinanceDocumentEvidenceContinuityTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      clerk_id: "document_evidence_#{SecureRandom.hex(6)}",
      email: "document-evidence-#{SecureRandom.hex(4)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
  end

  test "payload bounds IDs and stores metadata only" do
    imports = 6.times.map { |index| create_import(@household, @user, "ready-#{index}") }

    payload = HouseholdFinance::DocumentEvidenceContinuity.payload(
      {
        schema_version: 1,
        financial_document_import_ids: imports.map(&:id),
        raw_file_contents: "do not retain"
      },
      household: @household
    )

    assert_equal imports.first(5).map(&:id), payload.fetch("financial_document_import_ids")
    assert_equal 5, payload.fetch("import_count")
    assert_equal %w[financial_document_import_ids import_count schema_version], payload.keys.sort
  end

  test "ready payload rejects cross-household deleted processing and failed evidence" do
    other_user = User.create!(
      clerk_id: "other_document_evidence_#{SecureRandom.hex(6)}",
      email: "other-document-evidence-#{SecureRandom.hex(4)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    other_household = HouseholdFinance::WorkspaceResolver.new(other_user).household
    cross_household = create_import(other_household, other_user, "cross-household")

    assert_nil ready_payload([ cross_household.id ])

    %w[processing failed source_deleted].each do |status|
      document_import = create_import(@household, @user, status, status: status)
      assert_nil ready_payload([ document_import.id ]), "expected #{status} evidence to fail closed"
    end

    %w[applied partially_applied].each do |status|
      document_import = create_import(@household, @user, "source-deleted-#{status}", status: status)
      document_import.update_columns(source_deleted_at: Time.current, s3_key: nil)
      assert_nil ready_payload([ document_import.id ]), "expected source-deleted #{status} evidence to fail closed"
    end
  end

  test "conversation context revalidates every stored evidence ID through the session household" do
    valid = create_import(@household, @user, "valid")
    processing = create_import(@household, @user, "processing", status: "processing")
    topic = {
      schema_version: 4,
      id: SecureRandom.uuid,
      type: "document_evidence",
      title: "Prior uploads",
      subject: "uploaded financial documents",
      document_evidence: {
        schema_version: 1,
        financial_document_import_ids: [ valid.id, processing.id ]
      }
    }
    session = @household.chat_sessions.create!(user: @user, title: "Ask Mia", active_topic: topic, open_topics: [ topic ])

    context = HouseholdFinance::ConversationContextBuilder.new(session, household: @household).call

    assert_nil context.fetch(:active_topic)
    assert_empty context.fetch(:open_topics)
  end

  test "legacy topics cannot opt into document evidence without the evidence topic schema" do
    document_import = create_import(@household, @user, "legacy")
    topic = {
      schema_version: 2,
      type: "document_evidence",
      title: "Unvalidated evidence",
      document_evidence: {
        schema_version: 1,
        financial_document_import_ids: [ document_import.id ]
      }
    }

    assert_nil HouseholdFinance::DocumentEvidenceContinuity.sanitize_topic(topic, household: @household, require_ready: true)
  end

  private

  def ready_payload(ids)
    HouseholdFinance::DocumentEvidenceContinuity.payload(
      { schema_version: 1, financial_document_import_ids: ids },
      household: @household,
      require_ready: true
    )
  end

  def create_import(household, user, key, status: "needs_review")
    household.financial_document_imports.create!(
      uploaded_by_user: user,
      document_kind: "receipt",
      status: status,
      filename: "#{key}.png",
      content_type: "image/png",
      byte_size: 128,
      s3_key: status == "source_deleted" ? nil : "test/#{key}-#{SecureRandom.hex(4)}.png"
    )
  end
end
