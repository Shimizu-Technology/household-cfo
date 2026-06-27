require "test_helper"
require "tempfile"

class FinancialDocumentsExtractorTest < ActiveSupport::TestCase
  test "data URLs are base64 encoded in chunks without changing payload" do
    file = Tempfile.new("document-source")
    file.binmode
    payload = "abc" * 20_000 + "tail"
    file.write(payload)
    file.flush

    data_url = FinancialDocuments::Extractor.new(api_key: "test-key").send(:data_url, file.path, "application/pdf")

    assert_equal "data:application/pdf;base64,#{Base64.strict_encode64(payload)}", data_url
  ensure
    file&.close!
  end

  test "normalizes LLM item metadata to bounded allowlisted keys" do
    item = FinancialDocuments::Extractor.new(api_key: "test-key").send(
      :normalize_item,
      {
        "target_type" => "goal",
        "label" => "Vehicle fund",
        "amount" => 12_000,
        "balance" => nil,
        "payment" => nil,
        "cadence" => nil,
        "source_type" => nil,
        "stack_key" => nil,
        "account_type" => nil,
        "debt_type" => nil,
        "confidence" => "high",
        "evidence" => "Goal amount was visible.",
        "metadata" => {
          "goal_type" => "purchase",
          "raw_document_text" => "sensitive " * 1_000,
          "nested" => { "ignored" => true }
        }
      }
    )

    assert_equal({ "goal_type" => "purchase" }, item.fetch(:metadata))
  end

  test "rejects oversized inline sources before building OpenRouter payload" do
    user = User.create!(clerk_id: "clerk_extractor_payload_user", email: "extractor-payload@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Extractor Payload Household")
    household.household_memberships.create!(user: user, role: "owner")
    document_import = FinancialDocumentImport.create!(
      household: household,
      uploaded_by_user: user,
      document_kind: "statement",
      status: "uploaded",
      filename: "large-statement.pdf",
      content_type: "application/pdf",
      byte_size: 20,
      s3_key: "household-cfo/test/large-statement.pdf"
    )
    extractor = FinancialDocuments::Extractor.new(api_key: "test-key")

    extractor.define_singleton_method(:max_data_url_source_bytes) { 10 }
    with_s3_stubs(
      configured?: true,
      download_to_io: ->(_key, io) { io.write("oversized-source"); true }
    ) do
      result = extractor.call(document_import)

      assert_not result.success?
      assert_match(/too large/i, result.error)
    end
  end

  private

  def with_s3_stubs(stubs)
    originals = {}
    singleton = class << S3Service; self; end
    stubs.each do |method_name, replacement|
      originals[method_name] = singleton.instance_method(method_name) if singleton.method_defined?(method_name)
      singleton.define_method(method_name) do |*args, **kwargs, &block|
        if replacement.respond_to?(:call)
          replacement.call(*args, **kwargs, &block)
        else
          replacement
        end
      end
    end
    yield
  ensure
    stubs.each_key do |method_name|
      singleton.send(:remove_method, method_name) if singleton.method_defined?(method_name)
      singleton.define_method(method_name, originals[method_name]) if originals[method_name]
    end
  end
end
