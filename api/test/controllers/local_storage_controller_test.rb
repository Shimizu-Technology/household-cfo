# frozen_string_literal: true

require "test_helper"

class LocalStorageControllerTest < ActionDispatch::IntegrationTest
  setup do
    @previous_backend = ENV["STORAGE_BACKEND"]
    ENV["STORAGE_BACKEND"] = "local"
    @key = S3Service.namespaced_key("local-url-tests", SecureRandom.uuid)
  end

  teardown do
    ENV["STORAGE_BACKEND"] = "local"
    S3Service.delete!(@key)
    @previous_backend.nil? ? ENV.delete("STORAGE_BACKEND") : ENV["STORAGE_BACKEND"] = @previous_backend
  end

  test "signed PUT and GET round trip and method binding" do
    @key += "?question"
    bytes = "fictional statement"
    upload = S3Service.presigned_upload(@key, content_type: "text/plain", checksum_sha256: Digest::SHA256.hexdigest(bytes))
    put URI(upload[:url]).request_uri, params: bytes, headers: { "CONTENT_TYPE" => "text/plain" }
    assert_response :success
    get URI(upload[:url]).request_uri
    assert_response :forbidden
    url = S3Service.presigned_url(@key, filename: "statement.txt", disposition: :inline)
    get URI(url).request_uri
    assert_response :success
    assert_equal bytes, response.body
    assert_includes response.headers["Content-Disposition"], "inline"
    put URI(url).request_uri, params: bytes
    assert_response :forbidden
    S3Service.delete!(@key)
    get URI(url).request_uri
    assert_response :not_found
  end

  test "expired tampered and disabled capabilities are refused" do
    url = S3Service.presigned_url(@key, expires_in: -1)
    get URI(url).request_uri
    assert_response :forbidden
    get "/local_storage/tampered"
    assert_response :forbidden
    ENV.delete("STORAGE_BACKEND")
    get "/local_storage/tampered"
    assert_response :not_found
  end

  test "deletion after reading bytes returns not found" do
    S3Service.upload(@key, "fictional")
    url = S3Service.presigned_url(@key)
    original = S3Service.method(:download_to_io!)
    S3Service.define_singleton_method(:download_to_io!) do |key, io|
      original.call(key, io)
      S3Service.delete!(key)
      true
    end
    get URI(url).request_uri
    assert_response :not_found
  ensure
    S3Service.define_singleton_method(:download_to_io!, original) if original
  end

  test "PUT checksum mismatch does not create an object" do
    upload = S3Service.presigned_upload(@key, content_type: "text/plain", checksum_sha256: "a" * 64)
    put URI(upload[:url]).request_uri, params: "fictional", headers: { "CONTENT_TYPE" => "text/plain" }
    assert_response :bad_request
    assert_nil S3Service.object_metadata(@key)
  end
end
