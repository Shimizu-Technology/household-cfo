# frozen_string_literal: true

module Api
  module V1
    module Admin
      class CoachContentSourceUrlIntakesController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!
        before_action :set_intake, only: %i[show destroy retry_cleanup]
        rescue_from ActiveRecord::RecordNotFound, with: :not_found

        def index
          render json: feature_payload.merge(
            intakes: visible_intakes.where(scope: requested_scope).where.not(status: "deleted")
              .order(created_at: :desc, id: :desc).limit(100).map { |intake| serialize(intake) }
          )
        end

        def create
          return feature_disabled unless ContentSources::UrlIntake.enabled?
          return storage_unavailable unless S3Service.configured?

          normalized_url = ContentSources::UrlValidator.normalize!(params.require(:url))
          request_id = params.require(:request_id).to_s
          unless request_id.match?(/\A[A-Za-z0-9_-]{8,100}\z/)
            return render json: { error: "Refresh the page and try the address again.", code: "url_intake_request_invalid" }, status: :unprocessable_entity
          end

          scope = requested_scope
          return require_selected_coach_workspace! if scope == "coach" && coach_workspace_for_policy.nil?
          return render_intake_forbidden unless policy.can_upload_source?(scope)

          workspace = scope == "coach" ? coach_workspace_for_policy : nil
          quota = ContentSources::Quota.new(scope: scope, user: current_user, workspace: workspace)
          identity = ContentSources::UrlCipher.identity(normalized_url)
          intake = nil
          created = false
          ContentSources::OwnerLock.call("upload-quota:#{quota.owner_key}") do
            if quota.source_scope.where.not(status: "source_deleted").exists?(upload_request_id: request_id)
              raise ContentSources::Error, "url_intake_conflict"
            end
            intake = intake_scope(scope, workspace).find_by(request_id: request_id)
            if intake
              same_identity = identity_matches?(intake, normalized_url)
              raise ContentSources::Error, "url_intake_conflict" unless same_identity
              if intake.status == "failed"
                quota.enforce!(requested_bytes: CoachContentSourceUrlIntakeJob::RESERVATION_BYTES, exclude_intake: intake)
                intake.update!(
                  status: "queued", reserved_bytes: CoachContentSourceUrlIntakeJob::RESERVATION_BYTES,
                  error_code: nil, completed_at: nil
                )
              end
            else
              quota.enforce!(requested_bytes: CoachContentSourceUrlIntakeJob::RESERVATION_BYTES)
              encrypted = ContentSources::UrlCipher.encrypt(normalized_url)
              intake = CoachContentSourceUrlIntake.create!(
                scope: scope,
                coach_workspace: workspace,
                created_by_user: current_user,
                request_id: request_id,
                encrypted_url_ciphertext: encrypted.fetch(:ciphertext),
                encrypted_url_iv: encrypted.fetch(:iv),
                encrypted_url_auth_tag: encrypted.fetch(:auth_tag),
                encryption_key_version: encrypted.fetch(:key_version),
                url_identity_hmac: identity,
                hmac_key_version: ContentSources::UrlCipher.current_version,
                status: "queued",
                reserved_bytes: CoachContentSourceUrlIntakeJob::RESERVATION_BYTES
              )
              created = true
            end
          end
          job = CoachContentSourceUrlIntakeJob.perform_later(intake.id) if intake.status == "queued"
          raise ActiveJob::EnqueueError, "Secure URL intake could not be queued" if intake.status == "queued" && !job

          render json: feature_payload.merge(intake: serialize(intake.reload)), status: created ? :accepted : :ok
        rescue ActionController::ParameterMissing
          render json: { error: "Enter a source address and try again.", code: "url_intake_request_invalid" }, status: :unprocessable_entity
        rescue ContentSources::Error => error
          render json: { error: error.message, code: error.code }, status: :unprocessable_entity
        rescue ContentSources::UrlCipher::ConfigurationError
          render json: { error: ContentSources::Error::SAFE_MESSAGES.fetch("url_intake_unavailable"), code: "url_intake_unavailable" }, status: :service_unavailable
        rescue ActiveJob::EnqueueError
          intake&.destroy! if created && intake&.status == "queued"
          render json: { error: ContentSources::Error::SAFE_MESSAGES.fetch("url_intake_unavailable"), code: "url_intake_unavailable" }, status: :service_unavailable
        rescue ActiveRecord::RecordNotUnique
          render_concurrent_create(normalized_url)
        end

        def show
          render json: feature_payload.merge(intake: serialize(@intake))
        end

        def destroy
          return render_intake_forbidden unless policy.can_upload_source?(@intake.scope)
          return render json: feature_payload.merge(intake: serialize(@intake)), status: :ok if @intake.status == "deleted"
          if @intake.redaction_pending?
            enqueue_redaction_cleanup!
            return render json: feature_payload.merge(intake: serialize(@intake.reload)), status: :accepted
          end
          unless @intake.redaction_allowed?
            return render json: { error: "Only a failed, unregistered URL intake can be removed.", code: "url_intake_conflict" }, status: :unprocessable_entity
          end

          result = @intake.request_redaction!
          enqueue_redaction_cleanup! if result == :cleanup_required
          render json: feature_payload.merge(intake: serialize(@intake.reload)), status: result == :cleanup_required ? :accepted : :ok
        rescue ActiveJob::EnqueueError
          render json: { error: ContentSources::Error::SAFE_MESSAGES.fetch("url_intake_unavailable"), code: "url_intake_unavailable" }, status: :service_unavailable
        end

        def retry_cleanup
          unless current_user.admin?
            return render json: { error: "Only administrators can retry private URL cleanup.", code: "admin_required" }, status: :forbidden
          end
          retryable = @intake.status == "cleanup_failed" ||
            (@intake.status == "registered" && @intake.staging_s3_key.present? && @intake.error_code == "url_staging_cleanup_failed")
          unless retryable
            return render json: { error: "This URL intake cleanup is not retryable.", code: "url_cleanup_not_retryable" }, status: :unprocessable_entity
          end

          job = CoachContentSourceUrlCleanupJob.perform_later(@intake.id)
          raise ActiveJob::EnqueueError, "Secure URL cleanup could not be queued" unless job

          render json: feature_payload.merge(intake: serialize(@intake)), status: :accepted
        rescue ActiveJob::EnqueueError
          render json: { error: ContentSources::Error::SAFE_MESSAGES.fetch("url_intake_unavailable"), code: "url_intake_unavailable" }, status: :service_unavailable
        end

        private

        def policy
          @policy ||= Mia::ContentLibraryPolicy.new(current_user, workspace: coach_workspace_for_policy)
        end

        def requested_scope
          requested = params[:scope].to_s
          current_user.admin? ? requested.presence_in(CoachContentSource::SCOPES) || "platform" : "coach"
        end

        def intake_scope(scope, workspace)
          if scope == "coach"
            CoachContentSourceUrlIntake.where(scope: "coach", coach_workspace: workspace)
          else
            CoachContentSourceUrlIntake.where(scope: "platform", created_by_user: current_user, coach_workspace: nil)
          end
        end

        def set_intake
          @intake = visible_intakes.find(params[:id])
        end

        def visible_intakes
          if current_user.admin? && coach_workspace_for_policy.nil?
            CoachContentSourceUrlIntake.all
          elsif coach_workspace_for_policy && (current_user.admin? || coach_workspace_for_policy.allows?(current_user, :edit) || coach_workspace_for_policy.allows?(current_user, :review))
            coach = CoachContentSourceUrlIntake.where(scope: "coach", coach_workspace: coach_workspace_for_policy)
            current_user.admin? ? coach.or(CoachContentSourceUrlIntake.where(scope: "platform", coach_workspace: nil)) : coach
          else
            CoachContentSourceUrlIntake.none
          end
        end

        def enqueue_redaction_cleanup!
          job = CoachContentSourceUrlCleanupJob.perform_later(@intake.id)
          raise ActiveJob::EnqueueError, "Secure URL cleanup could not be queued" unless job
        end

        def serialize(intake)
          {
            id: intake.id,
            scope: intake.scope,
            status: intake.status,
            source_id: intake.coach_content_source_id,
            error_code: intake.error_code,
            error: intake.error_code && ContentSources::Error::SAFE_MESSAGES.fetch(intake.error_code, ContentSources::Error::SAFE_MESSAGES.fetch("processing_failed")),
            cleanup_retryable: current_user.admin? && (
              intake.status == "cleanup_failed" ||
              (intake.status == "registered" && intake.staging_s3_key.present? && intake.error_code == "url_staging_cleanup_failed")
            ),
            redaction_allowed: policy.can_upload_source?(intake.scope) && intake.redaction_allowed?,
            redaction_pending: intake.redaction_pending?,
            redirect_count: intake.redirect_count,
            created_at: intake.created_at,
            completed_at: intake.completed_at
          }
        end

        def render_intake_forbidden
          render json: { error: "Private source intake is not permitted.", code: "content_source_forbidden" }, status: :forbidden
        end

        def storage_unavailable
          render json: { error: ContentSources::Error::SAFE_MESSAGES.fetch("storage_unavailable"), code: "storage_unavailable" }, status: :service_unavailable
        end

        def feature_disabled
          render json: feature_payload.merge(
            error: ContentSources::Error::SAFE_MESSAGES.fetch("url_intake_disabled"), code: "url_intake_disabled"
          ), status: :service_unavailable
        end

        def feature_payload
          {
            url_intake: {
              enabled: ContentSources::UrlIntake.enabled?,
              available: ContentSources::UrlIntake.available?
            }
          }
        end

        def identity_matches?(intake, normalized_url)
          expected = ContentSources::UrlCipher.identity(normalized_url, version: intake.hmac_key_version)
          ActiveSupport::SecurityUtils.secure_compare(intake.url_identity_hmac, expected)
        end

        def render_concurrent_create(normalized_url)
          scope = requested_scope
          existing = intake_scope(scope, scope == "coach" ? coach_workspace_for_policy : nil).find_by(request_id: params[:request_id])
          return render json: feature_payload.merge(intake: serialize(existing)) if existing && identity_matches?(existing, normalized_url)

          render json: { error: ContentSources::Error::SAFE_MESSAGES.fetch("url_intake_conflict"), code: "url_intake_conflict" }, status: :conflict
        rescue ContentSources::UrlCipher::ConfigurationError
          render json: { error: ContentSources::Error::SAFE_MESSAGES.fetch("url_intake_unavailable"), code: "url_intake_unavailable" }, status: :service_unavailable
        end

        def not_found
          render json: { error: "Source intake not found.", code: "url_intake_not_found" }, status: :not_found
        end
      end
    end
  end
end
