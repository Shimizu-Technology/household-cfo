# frozen_string_literal: true

class S3Service
  MUTEX = Mutex.new

  class << self
    def safe_filename(filename, fallback: "upload")
      basename = filename.to_s.present? ? File.basename(filename.to_s) : ""
      safe = basename.gsub(/[^A-Za-z0-9._\-]/, "_").squeeze("_")
      safe = safe.gsub(/\A[._-]+/, "")
      safe.present? ? safe : fallback
    end

    def configured?
      bucket_name.present? &&
        ENV["AWS_ACCESS_KEY_ID"].present? &&
        ENV["AWS_SECRET_ACCESS_KEY"].present?
    end

    def bucket_name
      ENV.fetch("AWS_S3_BUCKET", nil)
    end

    def region
      ENV.fetch("AWS_REGION", "ap-southeast-2")
    end

    def prefix
      ENV.fetch("AWS_S3_PREFIX", default_prefix).to_s.gsub(%r{\A/+|/+\z}, "")
    end

    def namespaced_key(*parts)
      ([ prefix ] + parts.flatten).compact_blank.join("/").gsub(%r{/+}, "/")
    end

    def s3_client
      raise MissingConfigurationError, "AWS S3 storage is not configured" unless configured?

      signature = [ bucket_name, region, ENV["AWS_ACCESS_KEY_ID"], ENV["AWS_SECRET_ACCESS_KEY"] ].join(":")
      MUTEX.synchronize do
        if @s3_client.blank? || @client_signature != signature
          @s3_client = Aws::S3::Client.new(
            region: region,
            access_key_id: ENV.fetch("AWS_ACCESS_KEY_ID"),
            secret_access_key: ENV.fetch("AWS_SECRET_ACCESS_KEY")
          )
          @client_signature = signature
        end
        @s3_client
      end
    end

    def upload(key, data, content_type: "application/octet-stream")
      raise MissingConfigurationError, "AWS S3 storage is not configured" unless configured?

      s3_client.put_object(
        bucket: bucket_name,
        key: key,
        body: data,
        content_type: content_type,
        server_side_encryption: "AES256"
      )
      key
    rescue Aws::S3::Errors::ServiceError => e
      Rails.logger.error("[S3Service] Upload failed for #{key}: #{e.message}")
      nil
    end

    def download_to_io(key, io)
      raise MissingConfigurationError, "AWS S3 storage is not configured" unless configured?

      s3_client.get_object(bucket: bucket_name, key: key, response_target: io)
      io.flush if io.respond_to?(:flush)
      true
    rescue Aws::S3::Errors::ServiceError => e
      Rails.logger.error("[S3Service] Stream download failed for #{key}: #{e.message}")
      false
    end

    def presigned_url(key, expires_in: 300, filename: nil, disposition: :attachment)
      raise MissingConfigurationError, "AWS S3 storage is not configured" unless configured?

      presigner = Aws::S3::Presigner.new(client: s3_client)
      options = {
        bucket: bucket_name,
        key: key,
        expires_in: expires_in
      }
      if filename.present?
        escaped = filename.to_s.gsub(/["\\]/) { |ch| "\\#{ch}" }
        mode = disposition.to_sym == :inline ? "inline" : "attachment"
        options[:response_content_disposition] = %(#{mode}; filename="#{escaped}")
      end
      presigner.presigned_url(:get_object, **options)
    rescue Aws::S3::Errors::ServiceError => e
      Rails.logger.error("[S3Service] Presigned URL failed for #{key}: #{e.message}")
      nil
    end

    def delete(key)
      raise MissingConfigurationError, "AWS S3 storage is not configured" unless configured?
      return true if key.blank?

      s3_client.delete_object(bucket: bucket_name, key: key)
      true
    rescue Aws::S3::Errors::ServiceError => e
      Rails.logger.error("[S3Service] Delete failed for #{key}: #{e.message}")
      false
    end

    private

    def default_prefix
      "household-cfo/#{Rails.env}"
    end
  end

  class MissingConfigurationError < StandardError; end
end
