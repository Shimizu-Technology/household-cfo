# frozen_string_literal: true

require "digest"
require "fileutils"

# Development/test implementation of the private object storage contract.
class LocalObjectStore
  def upload(key, data, content_type:, checksum_sha256: nil)
    bytes = data.respond_to?(:read) ? data.read : data.to_s
    if checksum_sha256 && Digest::SHA256.hexdigest(bytes) != checksum_sha256
      raise Aws::S3::Errors::BadDigest.new(nil, "Checksum mismatch")
    end
    directory = path(key)
    FileUtils.mkdir_p(directory, mode: 0o700)
    File.open(directory.join("body"), "wb", 0o600) { |file| file.write(bytes) }
    File.open(directory.join("metadata.json"), "w", 0o600) { |file| file.write({ content_type: content_type }.to_json) }
    key
  end

  def download(key, io)
    io.binmode if io.respond_to?(:binmode)
    File.open(body_path(key), "rb") { |file| IO.copy_stream(file, io) }
    io.flush if io.respond_to?(:flush)
    true
  end

  def metadata(key)
    body = body_path(key)
    {
      byte_size: body.size,
      content_type: JSON.parse(File.read(path(key).join("metadata.json"))).fetch("content_type"),
      checksum_sha256: Base64.strict_encode64(Digest::SHA256.file(body).digest),
      etag: Digest::MD5.file(body).hexdigest,
      # Compatibility marker for existing completion checks; local disk is not S3-encrypted.
      server_side_encryption: "AES256"
    }
  rescue Aws::S3::Errors::NoSuchKey
    nil
  end

  def copy(source, destination)
    info = metadata(source)
    raise Aws::S3::Errors::NoSuchKey.new(nil, "Object not found") unless info

    File.open(body_path(source), "rb") { |file| upload(destination, file, content_type: info.fetch(:content_type)) }
  end

  def delete(key)
    return true if key.blank?

    directory = path(key)
    FileUtils.rm_f([ directory.join("body"), directory.join("metadata.json") ])
    true
  end

  def url(key, operation, expires_in:, **options)
    path(key)
    token = Rails.application.message_verifier(:local_object_store).generate(
      { key: key, operation: operation.to_s, **options }, expires_in: expires_in
    )
    origin = ENV.fetch("LOCAL_STORAGE_URL", "http://localhost:3000").delete_suffix("/")
    "#{origin}/local_storage/#{token}"
  end

  private

  def body_path(key)
    body = path(key).join("body")
    raise Aws::S3::Errors::NoSuchKey.new(nil, "Object not found") unless body.file?

    body
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
      raise ArgumentError, "Symlink in storage path" if cursor.symlink?

      cursor = cursor.parent
    end
    directory
  end
end
