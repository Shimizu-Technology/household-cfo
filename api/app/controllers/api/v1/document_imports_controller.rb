require "digest"
require "marcel"
require "zip"

module Api
  module V1
    class DocumentImportsController < BaseController
      before_action :authenticate_user!
      before_action :set_document_import, only: %i[show destroy reprocess apply source_url source_preview destroy_source]

      MAX_UPLOAD_BYTES = 20.megabytes
      ALLOWED_EXTENSIONS = %w[.pdf .csv .xls .xlsx .docx .jpg .jpeg .png .webp].freeze
      REJECTED_EXTENSIONS = %w[.doc .zip .rar .7z .exe .svg].freeze
      ALLOWED_CONTENT_TYPES_BY_EXTENSION = {
        ".pdf" => %w[application/pdf],
        ".csv" => %w[text/csv text/plain application/csv application/vnd.ms-excel],
        ".xls" => %w[application/vnd.ms-excel application/xls application/excel],
        ".xlsx" => %w[application/vnd.openxmlformats-officedocument.spreadsheetml.sheet application/zip],
        ".docx" => %w[application/vnd.openxmlformats-officedocument.wordprocessingml.document application/zip],
        ".jpg" => %w[image/jpeg],
        ".jpeg" => %w[image/jpeg],
        ".png" => %w[image/png],
        ".webp" => %w[image/webp]
      }.freeze
      EXTRACTION_METADATA_KEYS = %w[confidence warnings extraction_model last_extracted_at last_extraction_failed_at transaction_draft_count transaction_match_count].freeze

      def index
        imports = current_household.financial_document_imports
          .includes(:items, :uploaded_by_user, :applied_by_user, :source_deleted_by_user, transaction_drafts: [ :budget_category, :matched_transaction, { transaction_draft_splits: :budget_category, transaction_draft_matches: { household_transaction: { transaction_splits: :budget_category } } } ])
          .recent_first.limit(50)
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
        if @document_import.items.where.not(applied_at: nil).exists? || @document_import.transaction_drafts.where(status: %w[confirmed corrected matched]).exists?
          return render json: { errors: [ "Delete the source file instead; this import already applied or matched household values" ] }, status: :unprocessable_entity
        end

        source_key = @document_import.s3_key
        return render_s3_not_configured if source_key.present? && !S3Service.configured?

        document_import_id = @document_import.id
        @document_import.destroy!
        delete_source_after_destroy(source_key, document_import_id: document_import_id)
        head :no_content
      rescue S3Service::MissingConfigurationError
        render_s3_not_configured
      rescue ActiveRecord::RecordNotDestroyed
        render json: { errors: [ "Could not delete document import" ] }, status: :unprocessable_entity
      end

      def reprocess
        return render_s3_not_configured unless S3Service.configured?

        reprocess_error = nil
        @document_import.with_lock do
          unless @document_import.source_available?
            reprocess_error = "Document source is no longer available"
            next
          end

          if @document_import.applied? || @document_import.partially_applied? || @document_import.items.where.not(applied_at: nil).exists? || @document_import.transaction_drafts.where(status: %w[confirmed corrected matched]).exists?
            reprocess_error = "Applied document imports cannot be reprocessed; upload a new copy to extract updated values."
            next
          end

          @document_import.items.where(applied_at: nil).delete_all
          @document_import.transaction_drafts.pending.destroy_all
          @document_import.update!(
            status: "uploaded",
            extraction_error: nil,
            extracted_summary: nil,
            document_date: nil,
            period_start_on: nil,
            period_end_on: nil,
            processed_at: nil,
            metadata: reset_extraction_metadata(@document_import.metadata)
          )
        end
        return render json: { errors: [ reprocess_error ] }, status: :unprocessable_entity if reprocess_error

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

        inline_supported = inline_supported?(@document_import)
        url = S3Service.presigned_url(
          @document_import.s3_key,
          expires_in: 300,
          filename: @document_import.filename,
          disposition: inline_supported ? :inline : :attachment
        )
        download_url = S3Service.presigned_url(
          @document_import.s3_key,
          expires_in: 300,
          filename: @document_import.filename,
          disposition: :attachment
        )
        return render json: { errors: [ "Could not generate document link" ] }, status: :service_unavailable unless url && download_url

        render json: {
          url: url,
          download_url: download_url,
          expires_in: 300,
          filename: @document_import.filename,
          content_type: @document_import.content_type,
          inline_supported: inline_supported
        }
      rescue S3Service::MissingConfigurationError
        render_s3_not_configured
      end

      def source_preview
        return render_s3_not_configured unless S3Service.configured?
        return render json: { errors: [ "Document source is no longer available" ] }, status: :not_found unless @document_import.source_available?

        result = FinancialDocuments::SourcePreviewer.new(@document_import).call
        return render json: result.data if result.success?

        render json: { errors: [ result.error ] }, status: :unprocessable_entity
      rescue S3Service::MissingConfigurationError
        render_s3_not_configured
      end

      def destroy_source
        return render_s3_not_configured unless S3Service.configured?
        return render json: { document_import: serialize_document_import(@document_import) } if @document_import.s3_key.blank?

        source_key = @document_import.s3_key
        mark_source_deleted_before_s3_delete! unless @document_import.source_deleted_at.present?

        deleted = S3Service.delete(source_key)
        unless deleted
          Rails.logger.warn("[DocumentImportsController] marked source deleted for import #{@document_import.id} but could not delete private S3 source")
          return render json: { errors: [ "Could not delete document source" ], document_import: serialize_document_import(@document_import.reload) }, status: :service_unavailable
        end

        @document_import.update_columns(s3_key: nil, updated_at: Time.current)
        render json: { document_import: serialize_document_import(@document_import.reload) }
      rescue S3Service::MissingConfigurationError
        render_s3_not_configured
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved
        render json: { errors: [ "Could not update document source state" ] }, status: :unprocessable_entity
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
        return "Unsupported file type. Upload PDF, CSV, XLS, XLSX, DOCX, JPG, PNG, or WEBP." unless ALLOWED_EXTENSIONS.include?(extension)
        return "Uploaded file is empty" if File.zero?(file.tempfile.path)
        return "Uploaded file is too large (max #{MAX_UPLOAD_BYTES / 1.megabyte} MB)" if File.size(file.tempfile.path) > MAX_UPLOAD_BYTES

        content_type = sniffed_content_type(file)
        allowed_content_types = ALLOWED_CONTENT_TYPES_BY_EXTENSION.fetch(extension)
        unless content_type.in?(allowed_content_types)
          return "File contents do not match the #{extension.delete_prefix('.').upcase} upload type"
        end
        if extension.in?(%w[.docx .xlsx]) && !valid_ooxml_package?(file.tempfile.path, extension)
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
        return "spreadsheet" if extension.in?(%w[.csv .xls .xlsx])
        return "statement" if extension == ".pdf"
        return "other" if extension == ".docx"
        return "receipt" if extension.in?(%w[.jpg .jpeg .png .webp])

        "other"
      end

      def normalized_content_type(file)
        extension = File.extname(file.original_filename.to_s).downcase
        content_type = sniffed_content_type(file).presence || file.content_type.to_s.presence || "application/octet-stream"
        return "application/vnd.openxmlformats-officedocument.wordprocessingml.document" if extension == ".docx" && content_type == "application/zip"
        return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" if extension == ".xlsx" && content_type == "application/zip"

        content_type
      end

      def valid_ooxml_package?(path, extension)
        required_entry = extension == ".docx" ? "word/document.xml" : "xl/workbook.xml"
        Zip::File.open(path) do |zip|
          zip.find_entry("[Content_Types].xml").present? && zip.find_entry(required_entry).present?
        end
      rescue Zip::Error, SystemCallError
        false
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

      def delete_source_after_destroy(source_key, document_import_id:)
        return true if source_key.blank?

        deleted = S3Service.delete(source_key)
        Rails.logger.warn("[DocumentImportsController] deleted import #{document_import_id} but could not delete private S3 source") unless deleted
        deleted
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

      def mark_source_deleted_before_s3_delete!
        @document_import.update!(
          source_deleted_at: Time.current,
          source_deleted_by_user: current_user,
          status: source_deleted_status_for(@document_import)
        )
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
          transaction_drafts: ordered_transaction_drafts_for(document_import).map { |draft| serialize_transaction_draft(draft) },
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

      def ordered_transaction_drafts_for(document_import)
        scope = if document_import.association(:transaction_drafts).loaded?
          document_import.transaction_drafts
        else
          document_import.transaction_drafts.includes(:budget_category, :matched_transaction, transaction_draft_splits: :budget_category, transaction_draft_matches: { household_transaction: { transaction_splits: :budget_category } })
        end
        scope.sort_by { |draft| [ draft.occurred_on || Date.current, draft.id || 0 ] }.reverse
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

      def serialize_transaction_draft(draft)
        {
          id: draft.id,
          occurred_on: draft.occurred_on.iso8601,
          merchant: draft.merchant,
          amount: dollars_or_nil(draft.total_amount_cents),
          amount_cents: draft.total_amount_cents,
          status: draft.status,
          source_type: draft.source_type,
          financial_document_import_id: draft.financial_document_import_id,
          category_id: draft.budget_category_id,
          category_name: draft.budget_category&.name,
          stack_label: draft.budget_category&.stack_label,
          confidence: draft.confidence,
          raw_input: draft.raw_input,
          summary: "#{draft.merchant} — #{ActionController::Base.helpers.number_to_currency(dollars_or_nil(draft.total_amount_cents), precision: 2)}",
          splits: ordered_draft_splits_for(draft).map { |split| serialize_transaction_draft_split(split) },
          matches: ordered_draft_matches_for(draft).map { |match| serialize_transaction_draft_match(match) },
          matched_transaction_id: draft.matched_transaction_id,
          draft_payload: safe_draft_payload(draft.draft_payload)
        }
      end

      def ordered_draft_splits_for(draft)
        if draft.association(:transaction_draft_splits).loaded?
          draft.transaction_draft_splits.sort_by(&:id)
        else
          draft.transaction_draft_splits.ordered.includes(:budget_category)
        end
      end

      def ordered_draft_matches_for(draft)
        matches = if draft.association(:transaction_draft_matches).loaded?
          draft.transaction_draft_matches
        else
          draft.transaction_draft_matches.includes(household_transaction: { transaction_splits: :budget_category })
        end
        matches.sort_by { |match| [ -(match.confidence || 0).to_d, match.id || 0 ] }
      end

      def serialize_transaction_draft_split(split)
        {
          id: split.id,
          budget_category_id: split.budget_category_id,
          category_name: split.budget_category&.name || split.category_name,
          stack_key: split.budget_category&.stack_key || split.stack_key,
          stack_label: split.budget_category&.stack_label || split.stack_key.to_s.humanize,
          amount: dollars_or_nil(split.amount_cents),
          amount_cents: split.amount_cents,
          notes: split.notes,
          confidence: split.confidence,
          metadata: split.metadata || {}
        }
      end

      def serialize_transaction_draft_match(match)
        transaction = match.household_transaction
        {
          id: match.id,
          status: match.status,
          confidence: match.confidence,
          match_reason: match.match_reason,
          transaction: {
            id: transaction.id,
            occurred_on: transaction.occurred_on.iso8601,
            merchant: transaction.merchant,
            amount: dollars_or_nil(transaction.total_amount_cents),
            source_type: transaction.source_type,
            categories: transaction.transaction_splits.filter_map { |split| split.budget_category&.name }
          }
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
        (metadata || {}).slice("confidence", "warnings", "original_filename", "upload_request_id", "extraction_model", "last_extracted_at", "last_applied_count", "last_applied_at", "transaction_draft_count", "transaction_match_count")
      end

      def safe_draft_payload(payload)
        (payload || {}).slice("parser", "document_import_id", "row_index", "evidence", "external_id", "raw_description", "warnings")
      end

      def reset_extraction_metadata(metadata)
        (metadata || {}).except(*EXTRACTION_METADATA_KEYS)
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
