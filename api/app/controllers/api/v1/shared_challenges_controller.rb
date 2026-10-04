module Api
  module V1
    # Staff access never resolves a financial household workspace.
    class SharedChallengesController < BaseController
      before_action :authenticate_user!
      before_action :disable_caching!
      rescue_from ArgumentError do |error|
        render json: { errors: [ error.message ] }, status: :unprocessable_entity
      end
      rescue_from ChallengePrivacy::Access::Denied do |error|
        render json: { errors: [ error.message ] }, status: :forbidden
      end
      rescue_from SavingsChallenge::AccessPolicy::Unavailable do |error|
        render json: { errors: [ error.message ] }, status: :forbidden
      end
      rescue_from ActiveRecord::RecordNotFound do
        render json: { errors: [ "Shared record not found" ] }, status: :not_found
      end

      def basic = render(json: reader.basic)
      def summary = render(json: reader.summary)
      def scopes = render(json: reader.shared_scopes)
      def help = render(json: reader.help_page(after_id: params[:cursor].presence))
      def support_ticket = render(json: reader.support_ticket(params[:ticket_id]))
      def support_status = render(json: reader.update_support_status(params[:ticket_id], status: params[:status].to_s))

      def selected
        record = selected_record
        return render json: { record_type: "document_source", record_id: record.id, filename: record.filename,
          source_available: ChallengePrivacy::SourceRetention.available?(record), authenticated_content: true } if record.is_a?(FinancialDocumentImport)
        values = case record
        when SourceReviewVersion then record.attributes.slice("id", "version_number", "digest", "disposition", "event_type", "signed_amount_cents", "purchase_amount_cents", "posted_on", "merchant", "budget_category_id")
        when SavingsEntryVersion then record.attributes.slice("id", "version_number", "signed_cents", "effective_on", "funding_source", "digest")
        when SavingsPlanVersion then record.attributes.slice("id", "version_number", "target_cents", "reason", "digest")
        when ChatMessage then record.attributes.slice("id", "role", "content", "created_at")
        else raise ChallengePrivacy::Access::Denied, "This selected record is unavailable"
        end
        render json: { record_type: params[:record_type], record: values }
      end

      def source_content
        record = selected_record
        raise ChallengePrivacy::Access::Denied, "Choose an exact shared original" unless record.is_a?(FinancialDocumentImport)
        return render json: { errors: [ "Private source storage is unavailable" ] }, status: :service_unavailable unless S3Service.configured?
        key = record.s3_key
        bytes = FinancialDocuments::PrivateSourceReader.read(key)
        current = selected_record # Recheck current roles, recipient, scope, expiry and lease after storage IO.
        raise ChallengePrivacy::Access::Denied, "This selected original is unavailable" unless current.id == record.id && current.s3_key == key
        response.set_header("X-Content-Type-Options", "nosniff")
        response.set_header("Content-Security-Policy", "sandbox; default-src 'none'")
        inline = params[:download] != "1" && current.content_type.in?(%w[application/pdf image/jpeg image/png image/webp])
        send_data bytes, filename: S3Service.safe_filename(current.filename), type: inline ? current.content_type : "application/octet-stream",
          disposition: inline ? "inline" : "attachment"
      rescue S3Service::MissingConfigurationError, Aws::S3::Errors::ServiceError, Seahorse::Client::NetworkingError, IOError, Timeout::Error
        render json: { errors: [ "Private source could not be read. Try again." ] }, status: :service_unavailable
      rescue FinancialDocuments::PrivateSourceReader::TooLarge
        render json: { errors: [ "Private source exceeds the supported size." ] }, status: :unprocessable_entity
      end

      private

      def disable_caching! = response.set_header("Cache-Control", "private, no-store")
      def reader
        ChallengePrivacy::SharedReader.new(SavingsEnrollment.find(params[:enrollment_id]), user: current_user)
      end
      def selected_record
        id = params[:record_id].to_s
        raise ArgumentError, "Choose an exact record" unless id.match?(/\A[1-9]\d*\z/)
        reader.selected(record_type: params[:record_type].to_s, record_id: id.to_i, support_access_id: params[:support_access_id].presence)
      end
    end
  end
end
