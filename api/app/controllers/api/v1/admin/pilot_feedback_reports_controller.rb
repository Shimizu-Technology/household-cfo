module Api
  module V1
    module Admin
      class PilotFeedbackReportsController < BaseController
        class FeedbackAuditError < StandardError; end
        class FeedbackPersistenceError < StandardError; end

        SCREENSHOT_URL_TTL = 5.minutes.to_i

        before_action :authenticate_user!
        before_action :require_admin!
        before_action :set_report, only: %i[show update screenshot_url]
        rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

        def index
          requested_status = params[:status].to_s.presence || "submitted"
          unless requested_status == "all" || requested_status.in?(PilotFeedbackReport::STATUSES)
            return render json: { errors: [ "Feedback status is not valid" ] }, status: :unprocessable_entity
          end

          reports = PilotFeedbackReport.includes(:user).recent_first
          reports = reports.where(status: requested_status) unless requested_status == "all"

          render json: {
            feedback_reports: reports.limit(100).map { |report| serialize_summary(report) },
            counts: feedback_counts
          }
        end

        def show
          render json: { feedback_report: serialize_detail(@report) }
        end

        def update
          begin
            ApplicationRecord.transaction do
              @report.lock!
              previous_status = @report.status
              @report.update!(status: feedback_report_params.fetch(:status))
              record_status_change!(previous_status) if previous_status != @report.status
            end
          rescue ActiveRecord::RecordInvalid
            raise
          rescue ActiveRecord::ActiveRecordError => e
            raise FeedbackPersistenceError, e.message
          end

          render json: { feedback_report: serialize_detail(@report.reload) }
        rescue FeedbackAuditError
          render_feedback_unavailable
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue FeedbackPersistenceError => e
          Rails.logger.error("[Admin::PilotFeedbackReportsController] Feedback persistence failed: #{e.cause&.class || e.class}")
          render_feedback_unavailable
        rescue ActionController::ParameterMissing, KeyError
          render json: { errors: [ "Feedback status is required" ] }, status: :unprocessable_entity
        end

        def screenshot_url
          unless @report.screenshot?
            return render json: { errors: [ "This feedback report has no screenshot" ] }, status: :not_found
          end
          return render_s3_not_configured unless S3Service.configured?

          inline_url = S3Service.presigned_url(
            @report.screenshot_s3_key,
            expires_in: SCREENSHOT_URL_TTL,
            filename: @report.screenshot_filename,
            disposition: :inline
          )
          download_url = S3Service.presigned_url(
            @report.screenshot_s3_key,
            expires_in: SCREENSHOT_URL_TTL,
            filename: @report.screenshot_filename,
            disposition: :attachment
          )
          unless inline_url && download_url
            return render json: { errors: [ "Could not generate private screenshot links" ] }, status: :service_unavailable
          end

          render json: {
            url: inline_url,
            download_url: download_url,
            expires_in: SCREENSHOT_URL_TTL,
            filename: @report.screenshot_filename,
            content_type: @report.screenshot_content_type
          }
        rescue S3Service::MissingConfigurationError
          render_s3_not_configured
        end

        private

        def set_report
          @report = PilotFeedbackReport.includes(:user).find(params[:id])
        end

        def feedback_report_params
          params.require(:feedback_report).permit(:status)
        end

        def feedback_counts
          counts = PilotFeedbackReport.group(:status).count
          PilotFeedbackReport::STATUSES.to_h { |status| [ status, counts.fetch(status, 0) ] }
        end

        def serialize_summary(report)
          {
            id: report.id,
            workflow: report.workflow,
            status: report.status,
            screenshot_attached: report.screenshot?,
            reporter: serialize_reporter(report.user),
            created_at: report.created_at,
            updated_at: report.updated_at
          }
        end

        def serialize_detail(report)
          serialize_summary(report).merge(
            attempted: report.attempted,
            expected: report.expected,
            actual: report.actual,
            screenshot: report.screenshot? ? {
              filename: report.screenshot_filename,
              content_type: report.screenshot_content_type,
              byte_size: report.screenshot_byte_size
            } : nil
          )
        end

        def serialize_reporter(user)
          {
            id: user.id,
            email: user.email,
            full_name: user.full_name
          }
        end

        def record_status_change!(previous_status)
          @report.household.household_audit_events.create!(
            user: current_user,
            actor_type: "user",
            event_type: "pilot_feedback_report.status_changed",
            auditable_type: "PilotFeedbackReport",
            auditable_id: @report.id,
            occurred_at: Time.current,
            metadata: {
              previous_status: previous_status,
              status: @report.status
            }
          )
        rescue ActiveRecord::RecordInvalid => e
          raise FeedbackAuditError, e.message
        end

        def render_s3_not_configured
          render json: { errors: [ "Private screenshot storage is not configured" ] }, status: :service_unavailable
        end

        def render_feedback_unavailable
          render json: { errors: [ "This feedback report could not be updated right now. Please try again." ] }, status: :service_unavailable
        end

        def render_not_found(error)
          render json: { errors: [ error.message ] }, status: :not_found
        end
      end
    end
  end
end
