# frozen_string_literal: true

require "test_helper"

class LocalObjectStoreTest < ActiveSupport::TestCase
  setup do
    @previous_backend = ENV["STORAGE_BACKEND"]
    ENV["STORAGE_BACKEND"] = "local"
    @key = S3Service.namespaced_key("local-tests", SecureRandom.uuid, "statement.csv")
  end

  teardown do
    S3Service.delete!(@key)
    @previous_backend.nil? ? ENV.delete("STORAGE_BACKEND") : ENV["STORAGE_BACKEND"] = @previous_backend
  end

  test "round trip metadata copy and idempotent deletion" do
    assert S3Service.configured?
    assert_equal @key, S3Service.upload(@key, "date,amount\n\xFF".b, content_type: "text/csv")
    io = StringIO.new
    assert S3Service.download_to_io!(@key, io)
    assert_equal "date,amount\n\xFF".b, io.string
    assert_equal "text/csv", S3Service.object_metadata(@key)[:content_type]
    copy = "#{@key}/copy"
    begin
      assert_equal copy, S3Service.copy!(@key, copy)
      assert_equal S3Service.object_metadata(@key), S3Service.object_metadata(copy)
    ensure
      S3Service.delete!(copy)
    end
    assert S3Service.delete(@key)
    assert S3Service.delete!(@key)
    assert_nil S3Service.object_metadata(@key)
    assert_raises(Aws::S3::Errors::NoSuchKey) { S3Service.download_to_io!(@key, StringIO.new) }
    assert_equal false, S3Service.download_to_io(@key, StringIO.new)
  end

  test "file upload validates checksum" do
    Tempfile.create("local-upload") do |file|
      file.write("fictional")
      file.flush
      assert_equal @key, S3Service.upload_file!(@key, file.path, content_type: "text/plain", checksum_sha256: Digest::SHA256.hexdigest("fictional"))
      assert_raises(Aws::S3::Errors::BadDigest) do
        S3Service.upload_file!(@key, file.path, content_type: "text/plain", checksum_sha256: "a" * 64)
      end
    end
  end

  test "unsafe keys are refused" do
    [ "../escape", "/absolute", "a/../escape", "a//b", "a\\b", "a\0b" ].each do |key|
      assert_raises(ArgumentError) { S3Service.upload(key, "fictional") }
      assert_raises(ArgumentError) { S3Service.delete!(key) }
    end
  end

  test "symlinked storage directories are refused" do
    directory = LocalObjectStore.new.send(:path, @key)
    FileUtils.mkdir_p(directory.parent)
    Dir.mktmpdir("local-storage-outside") do |outside|
      File.symlink(outside, directory)
      assert_raises(ArgumentError) { S3Service.upload(@key, "fictional") }
    ensure
      File.unlink(directory) if directory.symlink?
    end
  end

  test "production refuses local mode even with AWS credentials" do
    original_env = Rails.method(:env)
    Rails.define_singleton_method(:env) { ActiveSupport::EnvironmentInquirer.new("production") }
    begin
      assert_raises(RuntimeError) { load Rails.root.join("config/initializers/local_storage.rb") }
      assert_raises(S3Service::MissingConfigurationError) { S3Service.configured? }
      assert_raises(S3Service::MissingConfigurationError) { S3Service.upload(@key, "fictional") }
    ensure
      Rails.define_singleton_method(:env, original_env)
    end
  end
end
