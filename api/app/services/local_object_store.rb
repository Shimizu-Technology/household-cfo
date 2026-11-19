# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "tempfile"

# Development/test implementation of the private object storage contract.
class LocalObjectStore
  def self.verifier
    ActiveSupport::MessageVerifier.new(
      Rails.application.key_generator.generate_key("local_object_store"),
      digest: "SHA256", serializer: JSON, url_safe: true
    )
  end

  def upload(key, data, content_type:, checksum_sha256: nil)
    bytes = data.respond_to?(:read) ? data.read : data.to_s
    if checksum_sha256 && Digest::SHA256.hexdigest(bytes) != checksum_sha256
      raise Aws::S3::Errors::BadDigest.new(nil, "Checksum mismatch")
    end
    directory = path(key)
    FileUtils.mkdir_p(directory, mode: 0o700)
    reject_symlink(directory.join("body"))
    # Publish the metadata header and bytes together. A failed write preserves
    # the previous object; readers with an open descriptor retain that snapshot.
    Tempfile.create("upload-", directory, binmode: true) do |file|
      file.write({ content_type: content_type }.to_json + "\n")
      file.write(bytes)
      file.flush
      file.fsync
      File.rename(file.path, directory.join("body"))
    end
    key
  rescue SystemCallError => error
    storage_error(error)
  end

  def download(key, io)
    io.binmode if io.respond_to?(:binmode)
    read_object(key) { |file, _info| IO.copy_stream(file, io) }
    io.flush if io.respond_to?(:flush)
    true
  end

  def metadata(key)
    read_object(key) do |file, info|
      bytes = file.read
      {
        byte_size: bytes.bytesize,
        content_type: info.fetch("content_type"),
        checksum_sha256: Base64.strict_encode64(Digest::SHA256.digest(bytes)),
        etag: Digest::MD5.hexdigest(bytes),
        # Compatibility marker for completion checks; local disk is not S3-encrypted.
        server_side_encryption: "AES256"
      }
    end
  rescue Aws::S3::Errors::NoSuchKey
    nil
  end

  def copy(source, destination)
    read_object(source) { |file, info| upload(destination, file, content_type: info.fetch("content_type")) }
  end

  def delete(key)
    return true if key.blank?

    File.unlink(path(key).join("body"))
    true
  rescue Errno::ENOENT
    true
  rescue SystemCallError => error
    storage_error(error)
  end

  def url(key, operation, expires_in:, **options)
    path(key)
    token = self.class.verifier.generate(
      { key: key, operation: operation.to_s, **options }, expires_in: expires_in
    )
    origin = ENV.fetch("LOCAL_STORAGE_URL", "http://localhost:3000").delete_suffix("/")
    "#{origin}/local_storage/#{token}"
  end

  private

  def read_object(key)
    body = path(key).join("body")
    reject_symlink(body)
    File.open(body, File::RDONLY | File::NOFOLLOW) do |file|
      file.binmode
      info = JSON.parse(file.readline)
      yield file, info
    end
  rescue Errno::ENOENT
    raise Aws::S3::Errors::NoSuchKey.new(nil, "Object not found")
  rescue SystemCallError => error
    storage_error(error)
  end

  def storage_error(error)
    raise Aws::S3::Errors::ServiceError.new(nil, "Local storage failure: #{error.class}")
  end

  def reject_symlink(file)
    raise ArgumentError, "Symlink in storage path" if file.symlink?
  end

  def path(key)
    raise S3Service::MissingConfigurationError, "Local storage is disabled" unless S3Service.local?

    parts = key.to_s.split("/", -1)
    if parts.empty? || parts.any? { |part| part.blank? || %w[. ..].include?(part) || part.include?("\\") || part.include?("\0") }
      raise ArgumentError, "Invalid storage key"
    end
    root = Rails.root.join("storage", "local_s3")
    # Hash components to fit filesystem limits and avoid internal filename collisions.
    directory = root.join(*parts.map { |part| Digest::SHA256.hexdigest(part) })
    cursor = directory
    while cursor != Rails.root
      reject_symlink(cursor)
      cursor = cursor.parent
    end
    directory
  end
end
