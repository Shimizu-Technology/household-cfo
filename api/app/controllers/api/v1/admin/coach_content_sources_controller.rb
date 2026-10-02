# frozen_string_literal: true

require "base64"
require "digest"
require "tempfile"

module Api
  module V1
    module Admin
      class CoachContentSourcesController < BaseController
        UploadPermissionRevoked = Class.new(StandardError)

        before_action :authenticate_user!
        before_action :require_staff!
        before_action :set_source, only: %i[show reprocess source_url destroy_source]
        rescue_from ActiveRecord::RecordNotFound, with: :not_found

        def index
          sources = policy.accessible_sources.where.not(status: "source_deleted").includes(:current_attempt)
            .order(Arel.sql("CASE WHEN status = 'upload_cleanup_failed' THEN 0 ELSE 1 END ASC"), created_at: :desc).limit(100)
          render json: {
            sources: sources.map { |source| serialize_source(source, include_candidates: false) },
            permissions: policy.source_collection_permissions
          }
        end

        def show
          render json: { source: serialize_source(@source) }
        end

        def presign
          metadata = upload_metadata
          return require_selected_coach_workspace! if metadata.fetch(:scope) == "coach" && coach_workspace_for_policy.nil?
          return render_forbidden("Private source upload not permitted") unless policy.can_upload_source?(metadata.fetch(:scope))
          metadata[:coach_workspace_id] = coach_workspace_for_policy.id if metadata.fetch(:scope) == "coach"
          return storage_unavailable unless S3Service.configured?

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

          token_metadata = metadata.merge(
            s3_key: key,
            source_id: source.id,
            user_id: current_user.id
          )
          token = upload_verifier.generate(token_metadata, expires_in: 15.minutes)
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
          metadata[:coach_workspace_id] ||= upload_intent_source(metadata)&.coach_workspace_id if metadata[:scope].to_s == "coach"
          return deny_upload_and_cleanup(metadata) unless current_upload_permission?(metadata)
          if metadata[:coach_workspace_id].present?
            selected_workspace = coach_workspace_for_policy
            return forbidden_upload unless selected_workspace && metadata[:coach_workspace_id].to_i == selected_workspace.id
          end
          existing = completed_upload_source(metadata)
          if existing
            claim_upload_cleanup!(upload_intent_source(metadata)) if existing.s3_key != metadata.fetch(:s3_key)
            CoachContentSourceProcessingJob.perform_later(existing.id) if existing.status == "queued"
            return render json: { source: serialize_source(existing) }
          end

          intent = claim_upload_verification!(metadata)
          object = S3Service.object_metadata(metadata.fetch(:s3_key))
          raise ContentSources::Error, "signature_mismatch" unless valid_object?(object, metadata)
          sniff_uploaded_object!(metadata)
          source, created = register_source!(metadata)
          claim_upload_cleanup!(intent) if source.s3_key != metadata.fetch(:s3_key)
          CoachContentSourceProcessingJob.perform_later(source.id) if source.status == "queued"
          render json: { source: serialize_source(source.reload) }, status: created ? :created : :ok
        rescue ActiveSupport::MessageVerifier::InvalidSignature, ActionController::ParameterMissing
          render json: { error: "The private upload expired. Choose the file and try again.", code: "upload_expired" }, status: :unprocessable_entity
        rescue UploadPermissionRevoked
          deny_upload_and_cleanup(metadata)
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
            render json: { source: serialize_source(source) }
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
          policy.visible_sources.where(status: "upload_cleanup_failed").order(:id).limit(100).find_each do |source|
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
            stale_processing = @source.status == "processing" && @source.updated_at <= CoachContentSourceProcessingJob::STALE_PROCESSING_AFTER.ago
            unless @source.source_available? && (@source.status.in?(%w[failed needs_review]) || stale_processing)
              return render json: { error: "This source cannot be retried in its current state.", code: "content_source_not_retryable" }, status: :unprocessable_entity
            end
            @source.update!(status: "queued", error_code: nil, error_message: nil, processed_at: nil)
            source = @source
          end
          CoachContentSourceProcessingJob.perform_later(source.id)
          render json: { source: serialize_source(source.reload) }
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
              return render json: { source: serialize_source(@source) }
            end
            unless @source.s3_key.present?
              return render json: { error: "This private source is no longer available.", code: "content_source_unavailable" }, status: :gone
            end

            now = Time.current
            CoachPhraseProposal.supersede_open_for_source!(@source, at: now)
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
          render json: { source: serialize_source(@source.reload) }, status: :accepted
        end

        private

        def policy
          @policy ||= Mia::ContentLibraryPolicy.new(current_user, workspace: coach_workspace_for_policy)
        end

        def serializer
          @serializer ||= ContentSources::Serializer.new
        end

        def serialize_source(source, include_candidates: true)
          serializer.source(source, include_candidates:, permissions: policy.source_permissions(source))
        end

        def set_source
          scope = action_name.in?(%w[show source_url]) ? policy.accessible_sources : policy.editable_sources
          @source = scope.find(params[:id])
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
          with_advisory_lock("checksum:#{upload_owner_key(metadata)}:#{metadata.fetch(:scope)}:#{metadata.fetch(:checksum_sha256)}") do
            raise UploadPermissionRevoked unless current_upload_permission_under_lock?(metadata)

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
          completed = source_owner_scope(metadata).where.not(
            status: %w[uploading verifying upload_cleanup upload_cleanup_failed deletion_pending deletion_failed source_deleted]
          )
          completed.find_by(upload_request_id: metadata.fetch(:upload_request_id)) ||
            policy.visible_sources.find_by(s3_key: metadata.fetch(:s3_key)) ||
            completed.where(
              scope: metadata.fetch(:scope),
              checksum_sha256: metadata.fetch(:checksum_sha256)
            ).recent_first.first
        end

        def create_upload_intent!(metadata)
          with_advisory_lock("upload-quota:#{upload_owner_key(metadata)}") do
            existing = source_owner_scope(metadata).find_by(upload_request_id: metadata.fetch(:upload_request_id))
            if existing
              same_identity = metadata.slice(:scope, :filename, :content_type, :byte_size, :checksum_sha256).all? { |key, value| existing.public_send(key) == value }
              raise ContentSources::Error, "upload_conflict" unless existing.status == "uploading" && same_identity

              next existing
            end
            enforce_upload_quota!(metadata)
            key = S3Service.namespaced_key("coach_content_sources", current_user.id, SecureRandom.uuid, "source")
            CoachContentSource.create!(
              metadata.slice(:scope, :filename, :content_type, :byte_size, :checksum_sha256, :upload_request_id).merge(
                created_by_user: current_user,
                coach_workspace: metadata.fetch(:scope) == "coach" ? current_coach_workspace : nil,
                status: "uploading",
                s3_key: key
              )
            )
          end
        end

        def enforce_upload_quota!(metadata)
          owned = source_owner_scope(metadata)
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
          scope = CoachContentSource.where(
            id: metadata[:source_id],
            created_by_user_id: metadata[:user_id],
            scope: metadata[:scope],
            upload_request_id: metadata[:upload_request_id],
            s3_key: metadata[:s3_key]
          )
          if metadata[:scope].to_s == "coach" && metadata[:coach_workspace_id].present?
            scope = scope.where(coach_workspace_id: metadata[:coach_workspace_id])
          elsif metadata[:scope].to_s == "platform"
            scope = scope.where(coach_workspace_id: nil)
          end
          scope.first
        end

        def source_owner_scope(metadata)
          if metadata.fetch(:scope).to_s == "coach"
            CoachContentSource.where(scope: "coach", coach_workspace_id: upload_workspace_id(metadata))
          else
            CoachContentSource.where(scope: "platform", created_by_user: current_user, coach_workspace_id: nil)
          end
        end

        def upload_owner_key(metadata)
          return "workspace-#{upload_workspace_id(metadata)}" if metadata.fetch(:scope).to_s == "coach"

          "platform-user-#{current_user.id}"
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

        def upload_workspace_id(metadata)
          metadata[:coach_workspace_id].presence&.to_i || upload_intent_source(metadata)&.coach_workspace_id
        end

        def current_upload_permission?(metadata)
          ApplicationRecord.transaction(requires_new: true) do
            current_upload_permission_under_lock?(metadata)
          end
        end

        def current_upload_permission_under_lock?(metadata)
          user = User.lock.find_by(id: metadata[:user_id])
          return false unless user && user.id == current_user.id

          workspace = nil
          if metadata[:scope].to_s == "coach"
            workspace_id = upload_workspace_id(metadata)
            return false unless workspace_id

            workspace = CoachWorkspace.find_by(id: workspace_id)
            return false unless workspace

            CoachWorkspaceMembership.where(coach_workspace_id: workspace.id, user_id: user.id).lock.load
          end
          Mia::ContentLibraryPolicy.new(user, workspace: workspace).can_upload_source?(metadata[:scope])
        end

        def deny_upload_and_cleanup(metadata)
          claim_upload_cleanup!(upload_intent_source(metadata))
          forbidden_upload
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
