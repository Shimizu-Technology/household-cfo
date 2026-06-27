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
end
