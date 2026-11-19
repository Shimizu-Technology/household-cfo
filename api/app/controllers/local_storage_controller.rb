# frozen_string_literal: true

# Like S3 presigned requests, these expiring capabilities are issued only by
# existing authorized callers. The token binds the object and HTTP operation.
class LocalStorageController < ApplicationController
  def show
    return head :not_found unless S3Service.local?

    payload = verified_payload("get")
    return head :forbidden unless payload

    io = StringIO.new
    S3Service.download_to_io!(payload.fetch("key"), io)
    metadata = S3Service.object_metadata(payload.fetch("key"))
    return head :not_found unless metadata

    send_data io.string, filename: S3Service.safe_filename(payload["filename"]),
      type: metadata.fetch(:content_type),
      disposition: payload["disposition"] == "inline" ? "inline" : "attachment"
  rescue Aws::S3::Errors::NoSuchKey
    head :not_found
  end

  def update
    return head :not_found unless S3Service.local?

    payload = verified_payload("put")
    return head :forbidden unless payload
    return head :bad_request unless request.media_type == payload.fetch("content_type")

    LocalObjectStore.new.upload(payload.fetch("key"), request.body,
      content_type: payload.fetch("content_type"), checksum_sha256: payload.fetch("checksum_sha256"))
    head :ok
  rescue Aws::S3::Errors::BadDigest
    head :bad_request
  end

  private

  def verified_payload(operation)
    payload = LocalObjectStore.verifier.verified(params[:token])
    payload if payload && payload["operation"] == operation
  end
end
