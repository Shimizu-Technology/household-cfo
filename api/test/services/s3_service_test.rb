require "test_helper"

class S3ServiceTest < ActiveSupport::TestCase
  test "synchronous cleanup uses bounded timeouts and leaves retries to the outbox" do
    original_access = ENV["AWS_ACCESS_KEY_ID"]
    original_secret = ENV["AWS_SECRET_ACCESS_KEY"]
    ENV["AWS_ACCESS_KEY_ID"] = "fictional-access"
    ENV["AWS_SECRET_ACCESS_KEY"] = "fictional-secret"
    client = S3Service.send(:cleanup_s3_client)
    assert_equal 3, client.config.http_open_timeout
    assert_equal 8, client.config.http_read_timeout
    assert_equal "legacy", client.config.retry_mode
    assert_equal 0, client.config.retry_limit
  ensure
    original_access.nil? ? ENV.delete("AWS_ACCESS_KEY_ID") : ENV["AWS_ACCESS_KEY_ID"] = original_access
    original_secret.nil? ? ENV.delete("AWS_SECRET_ACCESS_KEY") : ENV["AWS_SECRET_ACCESS_KEY"] = original_secret
  end

  test "download_to_io writes binary bytes unchanged into a text-mode file" do
    bytes = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n\x89PNG\r\n\x1A\n".b
    client = Aws::S3::Client.new(region: "ap-southeast-2", credentials: Aws::Credentials.new("test-access", "test-secret"), stub_responses: true)
    client.stub_responses(:get_object, body: bytes)
    env = %w[AWS_S3_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION].to_h { |key| [ key, ENV[key] ] }
    ENV.update("AWS_S3_BUCKET" => "fictional-bucket", "AWS_ACCESS_KEY_ID" => "fictional-access", "AWS_SECRET_ACCESS_KEY" => "fictional-secret", "AWS_REGION" => "ap-southeast-2")
    original = S3Service.method(:s3_client)
    S3Service.singleton_class.define_method(:s3_client) { client }

    Tempfile.create([ "text-mode", ".pdf" ]) do |file|
      S3Service.download_to_io!("household-cfo/test/statement.pdf", file)
      file.rewind
      assert_equal bytes, File.binread(file.path)
    end
  ensure
    S3Service.singleton_class.define_method(:s3_client, original) if original
    env&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  test "safe_filename strips path traversal and leading hidden-file dots" do
    assert_equal "statement.pdf", S3Service.safe_filename("../../statement.pdf")
    assert_equal "env", S3Service.safe_filename(".env")
    assert_equal "upload", S3Service.safe_filename("../..")
  end

  test "presigned upload returns the headers signed by the AWS SDK" do
    client = Aws::S3::Client.new(
      region: "ap-southeast-2",
      credentials: Aws::Credentials.new("test-access", "test-secret"),
      stub_responses: true
    )
    singleton = S3Service.singleton_class
    original_configured = singleton.instance_method(:configured?)
    original_client = singleton.instance_method(:s3_client)
    original_bucket = singleton.instance_method(:bucket_name)
    singleton.define_method(:configured?) { true }
    singleton.define_method(:s3_client) { client }
    singleton.define_method(:bucket_name) { "private-test-bucket" }

    upload = S3Service.presigned_upload("households/1/budget.csv", content_type: "text/csv", checksum_sha256: "a" * 64)

    assert_match %r{https://private-test-bucket\.s3\.ap-southeast-2\.amazonaws\.com/households/1/budget\.csv}, upload.fetch(:url)
    assert_equal "text/csv", upload.dig(:headers, "Content-Type")
    assert_equal "AES256", upload.dig(:headers, "x-amz-server-side-encryption")
    assert_equal Base64.strict_encode64([ "a" * 64 ].pack("H*")), upload.dig(:headers, "x-amz-checksum-sha256")
  ensure
    singleton&.send(:remove_method, :configured?) if singleton&.method_defined?(:configured?)
    singleton&.send(:remove_method, :s3_client) if singleton&.method_defined?(:s3_client)
    singleton&.send(:remove_method, :bucket_name) if singleton&.method_defined?(:bucket_name)
    singleton&.define_method(:configured?, original_configured) if original_configured
    singleton&.define_method(:s3_client, original_client) if original_client
    singleton&.define_method(:bucket_name, original_bucket) if original_bucket
  end


  test "snapshot staging upload and final copy require checksums and server-side encryption" do
    client = Aws::S3::Client.new(
      region: "ap-southeast-2",
      credentials: Aws::Credentials.new("test-access", "test-secret"),
      stub_responses: true
    )
    singleton = S3Service.singleton_class
    original_configured = singleton.instance_method(:configured?)
    original_client = singleton.instance_method(:s3_client)
    original_bucket = singleton.instance_method(:bucket_name)
    singleton.define_method(:configured?) { true }
    singleton.define_method(:s3_client) { client }
    singleton.define_method(:bucket_name) { "private-test-bucket" }
    tempfile = Tempfile.new([ "url-snapshot", ".txt" ])
    tempfile.write("private snapshot")
    tempfile.flush
    checksum = Digest::SHA256.file(tempfile.path).hexdigest

    S3Service.upload_file!("staging/source", tempfile.path, content_type: "text/plain", checksum_sha256: checksum)
    S3Service.copy!("staging/source", "final/source")

    put = client.api_requests.find { |request| request.fetch(:operation_name) == :put_object }.fetch(:params)
    copy = client.api_requests.find { |request| request.fetch(:operation_name) == :copy_object }.fetch(:params)
    assert_equal "AES256", put.fetch(:server_side_encryption)
    assert_equal Base64.strict_encode64([ checksum ].pack("H*")), put.fetch(:checksum_sha256)
    assert_equal "AES256", copy.fetch(:server_side_encryption)
    assert_equal "SHA256", copy.fetch(:checksum_algorithm)
    assert_equal "private-test-bucket/staging/source", copy.fetch(:copy_source)
  ensure
    tempfile&.close!
    singleton&.send(:remove_method, :configured?) if singleton&.method_defined?(:configured?)
    singleton&.send(:remove_method, :s3_client) if singleton&.method_defined?(:s3_client)
    singleton&.send(:remove_method, :bucket_name) if singleton&.method_defined?(:bucket_name)
    singleton&.define_method(:configured?, original_configured) if original_configured
    singleton&.define_method(:s3_client, original_client) if original_client
    singleton&.define_method(:bucket_name, original_bucket) if original_bucket
  end
end
