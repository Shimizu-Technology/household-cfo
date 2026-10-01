# frozen_string_literal: true

require "base64"
require "digest"
require "tempfile"

module Api
  module V1
    module Admin
      class CoachContentSourcesController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!
        before_action :set_source, only: %i[show reprocess source_url destroy_source]
        rescue_from ActiveRecord::RecordNotFound, with: :not_found

        def index
          sources = policy.visible_sources.where.not(status: "source_deleted").includes(:current_attempt)
            .order(Arel.sql("CASE WHEN status = 'upload_cleanup_failed' THEN 0 ELSE 1 END ASC"), created_at: :desc).limit(100)
          render json: { sources: sources.map { |source| serializer.source(source, include_candidates: false) } }
        end

        def show
          render json: { source: serializer.source(@source) }
        end

        def presign
          return storage_unavailable unless S3Service.configured?

          metadata = upload_metadata
          ContentSources::UploadValidator.validate_metadata!(**metadata.slice(:filename, :content_type, :byte_size, :checksum_sha256))
          unless metadata.fetch(:upload_request_id).match?(/\A[A-Za-z0-9_-]{8,100}\z/)
            return render json: { error: "Refresh the page and choose the file again.", code: "upload_request_invalid" }, status: :unprocessable_entity
          end
          source = create_upload_intent!(metadata)
          CoachContentSourceUploadExpiryJob.set(wait: 1.hour).perform_later(source.id)
          key = source.s3_key
          grant = S3Service.presigned_upload(
            key,
            content_type: metadata.fetch(:content_type),
            checksum_sha256: metadata.fetch(:checksum_sha256)
          )
          unless grant
            claim_upload_cleanup!(source)
            return storage_unavailable
          end

          token = upload_verifier.generate(metadata.merge(s3_key: key, source_id: source.id, user_id: current_user.id), expires_in: 15.minutes)
          render json: {
            upload_url: grant.fetch(:url),
            upload_headers: grant.fetch(:headers),
            upload_token: token,
            expires_in: grant.fetch(:expires_in)
          }
        rescue ContentSources::Error => error
          render_source_error(error)
        rescue Aws::S3::Errors::ServiceError, S3Service::MissingConfigurationError
          claim_upload_cleanup!(source) if defined?(source) && source
          storage_unavailable
        end

        def complete
          return storage_unavailable unless S3Service.configured?

          metadata = upload_verifier.verify(params.require(:upload_token)).deep_symbolize_keys
          return forbidden_upload unless metadata[:user_id].to_i == current_user.id
          existing = completed_upload_source(metadata)
          if existing
            claim_upload_cleanup!(upload_intent_source(metadata)) if existing.s3_key != metadata.fetch(:s3_key)
            CoachContentSourceProcessingJob.perform_later(existing.id) if existing.status == "queued"
            return render json: { source: serializer.source(existing) }
          end

          intent = claim_upload_verification!(metadata)
          object = S3Service.object_metadata(metadata.fetch(:s3_key))
          raise ContentSources::Error, "signature_mismatch" unless valid_object?(object, metadata)
          sniff_uploaded_object!(metadata)
          source, created = register_source!(metadata)
          claim_upload_cleanup!(intent) if source.s3_key != metadata.fetch(:s3_key)
          CoachContentSourceProcessingJob.perform_later(source.id) if source.status == "queued"
          render json: { source: serializer.source(source.reload) }, status: created ? :created : :ok
        rescue ActiveSupport::MessageVerifier::InvalidSignature, ActionController::ParameterMissing
          render json: { error: "The private upload expired. Choose the file and try again.", code: "upload_expired" }, status: :unprocessable_entity
        rescue ContentSources::Error => error
          claim_upload_cleanup!(upload_intent_source(metadata)) if defined?(metadata) && metadata
          render_source_error(error)
        rescue Aws::S3::Errors::ServiceError, S3Service::MissingConfigurationError
          storage_unavailable
        rescue ActiveRecord::RecordNotUnique
          source = completed_upload_source(metadata)
          if source
            claim_upload_cleanup!(upload_intent_source(metadata)) if source.s3_key != metadata.fetch(:s3_key)
            CoachContentSourceProcessingJob.perform_later(source.id) if source.status == "queued"
            render json: { source: serializer.source(source) }
          else
            render json: { error: "The private upload could not be registered safely.", code: "upload_conflict" }, status: :conflict
          end
        rescue ActiveRecord::RecordInvalid => error
          claim_upload_cleanup!(upload_intent_source(metadata)) if defined?(metadata) && metadata
          render json: { error: error.record.errors.full_messages.first, code: "content_source_invalid" }, status: :unprocessable_entity
        end

        def retry_upload_cleanups
          unless current_user.admin?
            return render json: { error: "Only administrators can retry private upload cleanup.", code: "admin_required" }, status: :forbidden
          end

          retried_count = 0
          CoachContentSource.where(status: "upload_cleanup_failed").order(:id).limit(100).find_each do |source|
            source.with_lock do
              next unless source.status == "upload_cleanup_failed"

              job = CoachContentSourceUploadExpiryJob.perform_later(source.id, admin_retry: true)
              raise ActiveJob::EnqueueError, "Private upload cleanup retry could not be queued." unless job

              retried_count += 1
            end
          end
          render json: { retried_count: retried_count }
        rescue ActiveJob::EnqueueError
          render json: { error: "Private upload cleanup could not be queued. Try again shortly.", code: "upload_cleanup_retry_unavailable" }, status: :service_unavailable
        end

        def reprocess
          source = nil
          @source.with_lock do
            unless @source.source_available? && @source.status.in?(%w[failed needs_review])
              return render json: { error: "This source cannot be retried in its current state.", code: "content_source_not_retryable" }, status: :unprocessable_entity
            end
            @source.update!(status: "queued", error_code: nil, error_message: nil, processed_at: nil)
            source = @source
          end
          CoachContentSourceProcessingJob.perform_later(source.id)
          render json: { source: serializer.source(source.reload) }
        end

        def source_url
          unless @source.source_available?
            return render json: { error: "This private source is no longer available.", code: "content_source_unavailable" }, status: :gone
          end
          url = S3Service.presigned_url(@source.s3_key, expires_in: 300, filename: @source.filename, disposition: :attachment)
          return storage_unavailable unless url

          render json: { url: url, download_url: url, expires_in: 300, filename: @source.filename, content_type: @source.content_type }
        rescue S3Service::MissingConfigurationError
          storage_unavailable
        end

        def destroy_source
          @source.with_lock do
            if @source.status == "source_deleted"
              return render json: { source: serializer.source(@source) }
            end
            unless @source.s3_key.present?
              return render json: { error: "This private source is no longer available.", code: "content_source_unavailable" }, status: :gone
            end

            now = Time.current
            current_attempt = @source.current_attempt
            if current_attempt&.status == "processing"
              current_attempt.update!(status: "superseded", error_code: "source_deletion", error_message: "Source deletion superseded this attempt.", completed_at: now)
            end
            @source.update!(
              status: "deletion_pending",
              generation: @source.generation + 1,
              deletion_requested_at: now,
              source_deleted_by_user: current_user,
              source_delete_error_code: nil
            )
          end
          CoachContentSourceDeletionJob.perform_later(@source.id)
          render json: { source: serializer.source(@source.reload) }, status: :accepted
        end

        private

        def policy
          @policy ||= Mia::ContentLibraryPolicy.new(current_user)
        end

        def serializer
          @serializer ||= ContentSources::Serializer.new
        end

        def set_source
          @source = policy.editable_sources.find(params[:id])
        end

        def upload_metadata
          filename = S3Service.safe_filename(params[:filename], fallback: "source#{File.extname(params[:filename].to_s).downcase}")
          requested_scope = params[:scope].to_s
          scope = current_user.admin? ? requested_scope.presence_in(CoachContentSource::SCOPES) || "platform" : "coach"
          {
            filename: filename,
            content_type: params[:content_type].to_s,
            byte_size: Integer(params[:byte_size], exception: false),
            checksum_sha256: params[:checksum_sha256].to_s.downcase,
            upload_request_id: params[:upload_request_id].to_s,
            scope: scope
          }
        end

        def valid_object?(object, metadata)
          return false unless object && object.fetch(:byte_size).to_i == metadata.fetch(:byte_size).to_i
          return false unless object[:content_type].to_s == metadata.fetch(:content_type)
          return false unless object[:server_side_encryption].to_s == "AES256"

          expected = Base64.strict_encode64([ metadata.fetch(:checksum_sha256) ].pack("H*"))
          ActiveSupport::SecurityUtils.secure_compare(object[:checksum_sha256].to_s, expected)
        end

        def sniff_uploaded_object!(metadata)
          Tempfile.create([ "coach-content-source", File.extname(metadata.fetch(:filename)) ]) do |file|
            S3Service.download_to_io!(metadata.fetch(:s3_key), file)
            file.flush
            ContentSources::UploadValidator.sniff!(path: file.path, filename: metadata.fetch(:filename))
          end
        end

        def register_source!(metadata)
          with_advisory_lock("checksum:#{current_user.id}:#{metadata.fetch(:scope)}:#{metadata.fetch(:checksum_sha256)}") do
            existing = completed_upload_source(metadata)
            if existing
              claim_upload_cleanup!(upload_intent_source(metadata)) if existing.s3_key != metadata.fetch(:s3_key)
              next [ existing, false ]
            end
            source = upload_intent_source(metadata)
            raise ContentSources::Error, "upload_expired" unless source

            source.with_lock do
              raise ContentSources::Error, "upload_expired" unless source.status == "verifying"
              source.update!(status: "queued")
            end
            [ source, true ]
          end
        end

        def completed_upload_source(metadata)
          policy.visible_sources.find_by(created_by_user_id: current_user.id, upload_request_id: metadata.fetch(:upload_request_id)) ||
            policy.visible_sources.find_by(s3_key: metadata.fetch(:s3_key)) ||
            policy.visible_sources.where(
              created_by_user_id: current_user.id,
              scope: metadata.fetch(:scope),
              checksum_sha256: metadata.fetch(:checksum_sha256)
            ).where.not(status: %w[uploading verifying upload_cleanup deletion_pending deletion_failed source_deleted]).recent_first.first
        end

        def create_upload_intent!(metadata)
          with_advisory_lock("upload-quota:#{current_user.id}") do
            existing = CoachContentSource.find_by(created_by_user_id: current_user.id, upload_request_id: metadata.fetch(:upload_request_id))
            if existing
              same_identity = metadata.slice(:scope, :filename, :content_type, :byte_size, :checksum_sha256).all? { |key, value| existing.public_send(key) == value }
              raise ContentSources::Error, "upload_conflict" unless existing.status == "uploading" && same_identity

              next existing
            end
            enforce_upload_quota!(metadata)
            key = S3Service.namespaced_key("coach_content_sources", current_user.id, SecureRandom.uuid, "source")
            CoachContentSource.create!(
              metadata.slice(:scope, :filename, :content_type, :byte_size, :checksum_sha256, :upload_request_id).merge(
                created_by_user: current_user, status: "uploading", s3_key: key
              )
            )
          end
        end

        def enforce_upload_quota!(metadata)
          owned = CoachContentSource.where(created_by_user_id: current_user.id)
          active = owned.where.not(status: "source_deleted")
          if active.count >= CoachContentSource::MAX_ACTIVE_SOURCES_PER_OWNER ||
              active.sum(:byte_size) + metadata.fetch(:byte_size) > CoachContentSource::MAX_ACTIVE_BYTES_PER_OWNER
            raise ContentSources::Error, "source_quota_reached"
          end
          if active.where(status: %w[uploading verifying upload_cleanup]).count >= CoachContentSource::MAX_IN_FLIGHT_UPLOADS_PER_OWNER
            raise ContentSources::Error, "upload_limit_reached"
          end
          if owned.where(created_at: CoachContentSource::UPLOAD_WINDOW.ago..).count >= CoachContentSource::MAX_NEW_UPLOADS_PER_WINDOW
            raise ContentSources::Error, "upload_rate_limited"
          end
        end

        def upload_intent_source(metadata)
          CoachContentSource.find_by(
            id: metadata[:source_id], created_by_user_id: current_user.id,
            upload_request_id: metadata[:upload_request_id], s3_key: metadata[:s3_key]
          )
        end

        def claim_upload_verification!(metadata)
          source = upload_intent_source(metadata)
          raise ContentSources::Error, "upload_expired" unless source

          source.with_lock do
            raise ContentSources::Error, "upload_expired" unless source.status.in?(%w[uploading verifying]) && source.created_at > 45.minutes.ago
            source.update!(status: "verifying") unless source.status == "verifying"
          end
          source
        end

        def claim_upload_cleanup!(source)
          return unless source

          source.with_lock do
            return unless source.status.in?(%w[uploading verifying upload_cleanup])
            source.update!(status: "upload_cleanup") unless source.status == "upload_cleanup"
          end
          CoachContentSourceUploadExpiryJob.perform_later(source.id)
        end

        def with_advisory_lock(value, &block)
          ApplicationRecord.transaction(requires_new: true) do
            first_key, second_key = Digest::SHA256.digest(value).unpack("l>2")
            integer = ActiveRecord::Type::Integer.new
            binds = [ first_key, second_key ].each_with_index.map do |value, index|
              ActiveRecord::Relation::QueryAttribute.new("key#{index}", value, integer)
            end
            ApplicationRecord.connection.exec_query("SELECT pg_advisory_xact_lock($1, $2)", "Coach content source upload lock", binds)
            block.call
          end
        end

        def upload_verifier
          Rails.application.message_verifier(:coach_content_source_direct_upload)
        end

        def render_source_error(error)
          render json: { error: error.message, code: error.code }, status: :unprocessable_entity
        end

        def storage_unavailable
          render json: { error: ContentSources::Error::SAFE_MESSAGES.fetch("storage_unavailable"), code: "storage_unavailable" }, status: :service_unavailable
        end

        def forbidden_upload
          render json: { error: "This upload does not belong to this coach.", code: "content_source_forbidden" }, status: :forbidden
        end

        def not_found
          render json: { error: "Content source not found.", code: "content_source_not_found" }, status: :not_found
        end
      end
    end
  end
end
