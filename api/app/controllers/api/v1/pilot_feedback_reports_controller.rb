require "marcel"

module Api
  module V1
    class PilotFeedbackReportsController < BaseController
      MAX_SCREENSHOT_BYTES = 5.megabytes
      ALLOWED_SCREENSHOT_TYPES = {
        ".jpg" => "image/jpeg",
        ".jpeg" => "image/jpeg",
        ".png" => "image/png",
        ".webp" => "image/webp"
      }.freeze

      before_action :authenticate_user!

      def create
        screenshot = params[:screenshot]
        screenshot_error = validate_screenshot(screenshot)
        return render json: { errors: [ screenshot_error ] }, status: :unprocessable_entity if screenshot_error

        report = current_household.pilot_feedback_reports.create!(
          feedback_params.merge(user: current_user)
        )

        if screenshot.present?
          stored = store_screenshot(report, screenshot)
          unless stored
            report.destroy!
            return render json: { errors: [ "The screenshot could not be stored privately. Your report was not submitted; please try again without it or retry later." ] }, status: :unprocessable_entity
          end
        end

        current_household.household_audit_events.create!(
          user: current_user,
          actor_type: "user",
          event_type: "pilot_feedback_report.submitted",
          auditable_type: "PilotFeedbackReport",
          auditable_id: report.id,
          metadata: { workflow: report.workflow, screenshot_attached: report.screenshot? },
          occurred_at: Time.current
        )

        render json: { feedback_report: serialize_report(report.reload) }, status: :created
      rescue S3Service::MissingConfigurationError
        render json: { errors: [ "Private screenshot storage is not configured. Submit without a screenshot or try again later." ] }, status: :service_unavailable
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      private

      def feedback_params
        params.require(:feedback_report).permit(:workflow, :attempted, :expected, :actual)
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

        report.update!(
          screenshot_s3_key: key,
          screenshot_filename: filename,
          screenshot_content_type: content_type,
          screenshot_byte_size: file.size
        )
        true
      end

      def serialize_report(report)
        {
          id: report.id,
          workflow: report.workflow,
          screenshot_attached: report.screenshot?,
          status: report.status,
          created_at: report.created_at
        }
      end
    end
  end
end
