require "marcel"

module Api
  module V1
    class PilotFeedbackReportsController < BaseController
      class ScreenshotStorageError < StandardError; end
      class FeedbackAuditError < StandardError; end
      class FeedbackPersistenceError < StandardError; end

      MAX_SCREENSHOT_BYTES = 5.megabytes
      ALLOWED_SCREENSHOT_TYPES = {
        ".jpg" => "image/jpeg",
        ".jpeg" => "image/jpeg",
        ".png" => "image/png",
        ".webp" => "image/webp"
      }.freeze

      before_action :authenticate_user!

      def index
        before_id = params[:before_id].presence
        if before_id && !before_id.to_s.match?(/\A[1-9]\d*\z/)
          return render json: { errors: [ "Report page is not valid" ] }, status: :unprocessable_entity
        end
        reports = own_reports.order(id: :desc)
        reports = reports.where("id < ?", before_id.to_i) if before_id
        page = reports.limit(21).to_a
        render json: { feedback_reports: page.first(20).map { |report| serialize_report(report) }, next_cursor: page.length > 20 ? page[19].id : nil }
      end

      def withdraw_support_access
        report = own_reports.find(params[:id])
        ApplicationRecord.transaction do
          report.lock!
          unless report.support_sharing_revoked_at
            report.update!(support_sharing_revoked_at: Time.current)
            current_household.household_audit_events.create!(user: current_user, actor_type: "user",
              event_type: "pilot_feedback_report.support_access_withdrawn", auditable_type: "PilotFeedbackReport", auditable_id: report.id,
              metadata: {}, occurred_at: Time.current)
          end
        end
        render json: { feedback_report: serialize_report(report) }
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "This report is not available to your account" ] }, status: :not_found
      rescue ActiveRecord::ActiveRecordError
        render json: { errors: [ "Support access could not be withdrawn. Please try again." ] }, status: :service_unavailable
      end

      def create
        report = nil
        stored_screenshot_key = nil
        screenshot = params[:screenshot]
        values = feedback_params
        consent = values.delete(:share_with_support).in?([ true, "true", "1" ])
        if ChallengePrivacy::PrivateFinanceAccess.pilot_household?(current_household) && !consent
          return render json: { errors: [ "Choose whether to share this technical report with app support before submitting. Your report was not sent." ] }, status: :unprocessable_entity
        end
        screenshot_error = validate_screenshot(screenshot)
        return render json: { errors: [ screenshot_error ] }, status: :unprocessable_entity if screenshot_error

        begin
          ApplicationRecord.transaction do
            report = current_household.pilot_feedback_reports.create!(
              values.merge(user: current_user, support_sharing_approved_at: consent ? Time.current : nil,
                support_sharing_policy_version: consent ? PilotFeedbackReport::SUPPORT_SHARING_POLICY_VERSION : nil)
            )

            if screenshot.present?
              stored = store_screenshot(report, screenshot) { |key| stored_screenshot_key = key }
              raise ScreenshotStorageError unless stored
            end

            record_submission_audit!(report)
          end
        rescue ActiveRecord::RecordInvalid
          raise
        rescue ActiveRecord::ActiveRecordError => e
          raise FeedbackPersistenceError, e.message
        end

        render json: { feedback_report: serialize_report(report) }, status: :created
      rescue ScreenshotStorageError
        cleanup_stored_screenshot(stored_screenshot_key)
        render json: { errors: [ "The screenshot could not be stored privately. Your report was not submitted; please try again without it or retry later." ] }, status: :unprocessable_entity
      rescue S3Service::MissingConfigurationError
        cleanup_stored_screenshot(stored_screenshot_key)
        render json: { errors: [ "Private screenshot storage is not configured. Submit without a screenshot or try again later." ] }, status: :service_unavailable
      rescue FeedbackAuditError
        cleanup_stored_screenshot(stored_screenshot_key)
        render json: { errors: [ "Your report could not be submitted right now. Please try again." ] }, status: :service_unavailable
      rescue ActiveRecord::RecordInvalid => e
        cleanup_stored_screenshot(stored_screenshot_key)
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue FeedbackPersistenceError => e
        cleanup_stored_screenshot(stored_screenshot_key)
        Rails.logger.error("[PilotFeedbackReportsController] Feedback persistence failed: #{e.cause&.class || e.class}")
        render json: { errors: [ "Your report could not be submitted right now. Please try again." ] }, status: :service_unavailable
      end

      private

      def own_reports = current_household.pilot_feedback_reports.where(user: current_user)

      def feedback_params
        raise ActionController::ParameterMissing, :feedback_report unless params[:feedback_report].is_a?(ActionController::Parameters)
        params.require(:feedback_report).permit(:workflow, :attempted, :expected, :actual, :share_with_support)
      end

      def validate_screenshot(file)
        return nil if file.blank?
        return "Screenshot must be an uploaded image" unless file.respond_to?(:tempfile) && file.respond_to?(:original_filename)
        return "Screenshot must be 5 MB or smaller" if file.size.to_i > MAX_SCREENSHOT_BYTES
        return "Screenshot is empty" if file.size.to_i <= 0
        return "Private screenshot storage is not configured" unless S3Service.configured?

        extension = File.extname(file.original_filename.to_s).downcase
        expected_type = ALLOWED_SCREENSHOT_TYPES[extension]
        return "Screenshot must be a JPG, PNG, or WebP image" unless expected_type

        detected_type = Marcel::MimeType.for(file.tempfile)
        file.tempfile.rewind
        return "Screenshot content does not match its file type" unless detected_type == expected_type

        nil
      end

      def store_screenshot(report, file)
        extension = File.extname(file.original_filename.to_s).downcase
        content_type = ALLOWED_SCREENSHOT_TYPES.fetch(extension)
        filename = S3Service.safe_filename(file.original_filename, fallback: "pilot-feedback")
        filename = "pilot-feedback#{extension}" if File.extname(filename).blank?
        key = S3Service.namespaced_key("households", current_household.id, "pilot-feedback", report.id, filename)
        uploaded = File.open(file.tempfile.path, "rb") do |io|
          S3Service.upload(key, io, content_type: content_type)
        end
        return false unless uploaded

        yield key if block_given?
        report.update!(
          screenshot_s3_key: key,
          screenshot_filename: filename,
          screenshot_content_type: content_type,
          screenshot_byte_size: file.size
        )
        key
      end

      def cleanup_stored_screenshot(key)
        return if key.blank?
        return if S3Service.delete(key)

        Rails.logger.error("[PilotFeedbackReportsController] Private screenshot cleanup failed")
      rescue StandardError => e
        Rails.logger.error("[PilotFeedbackReportsController] Private screenshot cleanup failed: #{e.class}")
      end

      def record_submission_audit!(report)
        current_household.household_audit_events.create!(
          user: current_user,
          actor_type: "user",
          event_type: "pilot_feedback_report.submitted",
          auditable_type: "PilotFeedbackReport",
          auditable_id: report.id,
          metadata: { workflow: report.workflow, screenshot_attached: report.screenshot? }.merge(report.support_sharing_granted? ? { support_sharing_policy_version: report.support_sharing_policy_version, support_scope: "report_text_and_optional_screenshot" } : {}),
          occurred_at: Time.current
        )
      rescue ActiveRecord::RecordInvalid => e
        raise FeedbackAuditError, e.message
      end

      def serialize_report(report)
        {
          id: report.id,
          workflow: report.workflow,
          screenshot_attached: report.screenshot?,
          status: report.status,
          created_at: report.created_at,
          support_sharing_granted: report.support_sharing_granted?,
          support_access_available: report.support_access_available?
        }
      end
    end
  end
end
