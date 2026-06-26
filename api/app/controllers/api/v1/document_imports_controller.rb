require "digest"
require "marcel"

module Api
  module V1
    class DocumentImportsController < BaseController
      before_action :authenticate_user!
      before_action :set_document_import, only: %i[show destroy reprocess apply source_url destroy_source]

      MAX_UPLOAD_BYTES = 20.megabytes
      ALLOWED_EXTENSIONS = %w[.pdf .csv .xlsx .jpg .jpeg .png .webp].freeze
      REJECTED_EXTENSIONS = %w[.xls .zip .rar .7z .exe .svg].freeze
      ALLOWED_CONTENT_TYPES_BY_EXTENSION = {
        ".pdf" => %w[application/pdf],
        ".csv" => %w[text/csv text/plain application/csv application/vnd.ms-excel],
        ".xlsx" => %w[application/vnd.openxmlformats-officedocument.spreadsheetml.sheet application/zip],
        ".jpg" => %w[image/jpeg],
        ".jpeg" => %w[image/jpeg],
        ".png" => %w[image/png],
        ".webp" => %w[image/webp]
      }.freeze

      def index
        imports = current_household.financial_document_imports.includes(:items, :attempts, :uploaded_by_user, :applied_by_user, :source_deleted_by_user).recent_first.limit(50)
        render json: { document_imports: imports.map { |document_import| serialize_document_import(document_import) } }
      end

      def show
        render json: { document_import: serialize_document_import(@document_import, include_attempts: true) }
      end

      def create
        return render_s3_not_configured unless S3Service.configured?

        file = params[:file]
        return render json: { errors: [ "No file uploaded" ] }, status: :unprocessable_entity unless valid_upload_param?(file)

        validation_error = upload_validation_error(file)
        return render json: { errors: [ validation_error ] }, status: :unprocessable_entity if validation_error

        document_import = build_document_import(file)
        document_import.save!

        s3_key = s3_key_for(document_import, file)
        uploaded = File.open(file.tempfile.path, "rb") do |io|
          S3Service.upload(s3_key, io, content_type: document_import.content_type)
        end
        unless uploaded
          cleanup_failed_upload_import!(document_import)
          return render json: { errors: [ "Could not store document in private S3" ] }, status: :unprocessable_entity
        end

        document_import.update!(s3_key: s3_key)
        FinancialDocumentExtractionJob.perform_later(document_import.id)

        render json: { document_import: serialize_document_import(document_import.reload) }, status: :created
      rescue S3Service::MissingConfigurationError
        render_s3_not_configured
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ActiveRecord::RecordNotDestroyed
        render json: { errors: [ "Could not clean up failed document import" ] }, status: :internal_server_error
      end

      def destroy
        if @document_import.items.where.not(applied_at: nil).exists?
          return render json: { errors: [ "Delete the source file instead; this import already applied household values" ] }, status: :unprocessable_entity
        end

        deleted = delete_source_if_present(@document_import)
        return render json: { errors: [ "Could not delete document source" ] }, status: :service_unavailable unless deleted

        @document_import.destroy!
        head :no_content
      rescue S3Service::MissingConfigurationError
        render_s3_not_configured
      end

      def reprocess
        return render_s3_not_configured unless S3Service.configured?
        return render json: { errors: [ "Document source is no longer available" ] }, status: :unprocessable_entity unless @document_import.source_available?

        @document_import.with_lock do
          @document_import.items.where(applied_at: nil).delete_all
          @document_import.update!(status: "uploaded", extraction_error: nil, processed_at: nil)
        end
        FinancialDocumentExtractionJob.perform_later(@document_import.id)
        render json: { document_import: serialize_document_import(@document_import.reload) }
      end

      def apply
        result = HouseholdFinance::DocumentImportApplier.new(
          @document_import,
          user: current_user,
          item_ids: params[:item_ids]
        ).call

        unless result.success?
          return render json: { errors: result.errors }, status: :unprocessable_entity
        end

        render json: {
          document_import: serialize_document_import(result.import, include_attempts: true),
          applied_count: result.applied_count,
          workspace: HouseholdFinance::DataPresenter.new(current_household, user: current_user).app_data
        }
      end

      def source_url
        return render_s3_not_configured unless S3Service.configured?
        return render json: { errors: [ "Document source is no longer available" ] }, status: :not_found unless @document_import.source_available?

        url = S3Service.presigned_url(
          @document_import.s3_key,
          expires_in: 300,
          filename: @document_import.filename,
          disposition: inline_supported?(@document_import) ? :inline : :attachment
        )
        return render json: { errors: [ "Could not generate document link" ] }, status: :service_unavailable unless url

        render json: {
          url: url,
          expires_in: 300,
          filename: @document_import.filename,
          content_type: @document_import.content_type,
          inline_supported: inline_supported?(@document_import)
        }
      rescue S3Service::MissingConfigurationError
        render_s3_not_configured
      end

      def destroy_source
        return render_s3_not_configured unless S3Service.configured?
        return render json: { document_import: serialize_document_import(@document_import) } unless @document_import.source_available?

        deleted = S3Service.delete(@document_import.s3_key)
        return render json: { errors: [ "Could not delete document source" ] }, status: :service_unavailable unless deleted

        @document_import.update!(
          s3_key: nil,
          source_deleted_at: Time.current,
          source_deleted_by_user: current_user,
          status: source_deleted_status_for(@document_import)
        )
        render json: { document_import: serialize_document_import(@document_import.reload) }
      rescue S3Service::MissingConfigurationError
        render_s3_not_configured
      end

      private

      def set_document_import
        @document_import = current_household.financial_document_imports.find(params[:id])
      end

      def valid_upload_param?(file)
        file.respond_to?(:tempfile) && file.respond_to?(:original_filename)
      end

      def upload_validation_error(file)
        filename = file.original_filename.to_s
        extension = File.extname(filename).downcase
        return "Unsupported file type" if REJECTED_EXTENSIONS.include?(extension)
        return "Unsupported file type. Upload PDF, CSV, XLSX, JPG, PNG, or WEBP." unless ALLOWED_EXTENSIONS.include?(extension)
        return "Uploaded file is empty" if File.zero?(file.tempfile.path)
        return "Uploaded file is too large (max #{MAX_UPLOAD_BYTES / 1.megabyte} MB)" if File.size(file.tempfile.path) > MAX_UPLOAD_BYTES

        content_type = sniffed_content_type(file)
        allowed_content_types = ALLOWED_CONTENT_TYPES_BY_EXTENSION.fetch(extension)
        unless content_type.in?(allowed_content_types)
          return "File contents do not match the #{extension.delete_prefix('.').upcase} upload type"
        end

        nil
      end

      def build_document_import(file)
        FinancialDocumentImport.new(
          household: current_household,
          uploaded_by_user: current_user,
          document_kind: requested_document_kind(file),
          status: "uploaded",
          filename: S3Service.safe_filename(File.basename(file.original_filename.to_s.presence || "upload"), fallback: "upload"),
          content_type: normalized_content_type(file),
          byte_size: File.size(file.tempfile.path),
          checksum_sha256: Digest::SHA256.file(file.tempfile.path).hexdigest,
          metadata: {
            "original_filename" => file.original_filename.to_s,
            "upload_request_id" => params[:upload_request_id].to_s.presence
          }.compact
        )
      end

      def requested_document_kind(file)
        requested = params[:document_kind].to_s
        return requested if requested.in?(FinancialDocumentImport::DOCUMENT_KINDS)

        extension = File.extname(file.original_filename.to_s).downcase
        return "spreadsheet" if extension.in?(%w[.csv .xlsx])
        return "statement" if extension == ".pdf"
        return "receipt" if extension.in?(%w[.jpg .jpeg .png .webp])

        "other"
      end

      def normalized_content_type(file)
        sniffed_content_type(file).presence || file.content_type.to_s.presence || "application/octet-stream"
      end

      def sniffed_content_type(file)
        Marcel::MimeType.for(Pathname(file.tempfile.path), name: file.original_filename)
      end

      def s3_key_for(document_import, file)
        S3Service.namespaced_key(
          "households",
          document_import.household_id,
          "documents",
          document_import.id,
          "source",
          S3Service.safe_filename(File.basename(file.original_filename.to_s.presence || document_import.filename), fallback: document_import.filename)
        )
      end

      def delete_source_if_present(document_import)
        return true unless document_import.s3_key.present?

        S3Service.delete(document_import.s3_key)
      end

      def cleanup_failed_upload_import!(document_import)
        document_import.destroy!
      rescue ActiveRecord::RecordNotDestroyed
        document_import.update_columns(
          status: "failed",
          extraction_error: "Private S3 upload failed before extraction; cleanup could not remove the import.",
          processed_at: Time.current,
          updated_at: Time.current
        )
        raise
      end

      def source_deleted_status_for(document_import)
        return document_import.status if document_import.applied? || document_import.partially_applied?

        "source_deleted"
      end

      def inline_supported?(document_import)
        document_import.pdf? || document_import.image?
      end

      def serialize_document_import(document_import, include_attempts: false)
        {
          id: document_import.id,
          household_id: document_import.household_id,
          document_kind: document_import.document_kind,
          status: document_import.status,
          filename: document_import.filename,
          content_type: document_import.content_type,
          byte_size: document_import.byte_size,
          document_date: document_import.document_date,
          period_start_on: document_import.period_start_on,
          period_end_on: document_import.period_end_on,
          extracted_summary: document_import.extracted_summary,
          extraction_error: document_import.extraction_error,
          processed_at: document_import.processed_at,
          applied_at: document_import.applied_at,
          source_deleted_at: document_import.source_deleted_at,
          source_available: document_import.source_available?,
          uploaded_by: serialize_user_reference(document_import.uploaded_by_user),
          applied_by: serialize_user_reference(document_import.applied_by_user),
          source_deleted_by: serialize_user_reference(document_import.source_deleted_by_user),
          metadata: safe_import_metadata(document_import.metadata),
          items: ordered_items_for(document_import).map { |item| serialize_item(item) },
          attempts: include_attempts ? document_import.attempts.recent_first.limit(5).map { |attempt| serialize_attempt(attempt) } : []
        }
      end

      def ordered_items_for(document_import)
        if document_import.association(:items).loaded?
          document_import.items.sort_by(&:id)
        else
          document_import.items.order(:id)
        end
      end

      def serialize_item(item)
        {
          id: item.id,
          target_type: item.target_type,
          label: item.label,
          amount: dollars_or_nil(item.amount_cents),
          amount_cents: item.amount_cents,
          balance: dollars_or_nil(item.balance_cents),
          balance_cents: item.balance_cents,
          payment: dollars_or_nil(item.payment_cents),
          payment_cents: item.payment_cents,
          cadence: item.cadence,
          source_type: item.source_type,
          stack_key: item.stack_key,
          account_type: item.account_type,
          debt_type: item.debt_type,
          confidence: item.confidence,
          evidence: item.evidence,
          selected: item.selected,
          ignored: item.ignored,
          applied_at: item.applied_at,
          applied_record_type: item.applied_record_type,
          applied_record_id: item.applied_record_id,
          metadata: item.metadata || {}
        }
      end

      def serialize_attempt(attempt)
        {
          id: attempt.id,
          provider: attempt.provider,
          model: attempt.model,
          status: attempt.status,
          prompt_version: attempt.prompt_version,
          schema_version: attempt.schema_version,
          error: attempt.error,
          started_at: attempt.started_at,
          completed_at: attempt.completed_at,
          metadata: attempt.metadata || {}
        }
      end

      def serialize_user_reference(user)
        return nil unless user

        {
          id: user.id,
          email: user.email,
          full_name: user.full_name
        }
      end

      def safe_import_metadata(metadata)
        (metadata || {}).slice("confidence", "warnings", "original_filename", "upload_request_id", "extraction_model", "last_extracted_at", "last_applied_count", "last_applied_at")
      end

      def dollars_or_nil(cents)
        return nil if cents.nil?

        HouseholdFinance::Money.dollars(cents)
      end

      def render_s3_not_configured
        render json: { errors: [ "Private S3 document storage is not configured" ] }, status: :service_unavailable
      end
    end
  end
end
