require "test_helper"

class S3ServiceTest < ActiveSupport::TestCase
  test "safe_filename strips path traversal and leading hidden-file dots" do
    assert_equal "statement.pdf", S3Service.safe_filename("../../statement.pdf")
    assert_equal "env", S3Service.safe_filename(".env")
    assert_equal "upload", S3Service.safe_filename("../..")
  end
end
