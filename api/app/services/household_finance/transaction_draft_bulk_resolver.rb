module HouseholdFinance
  class TransactionDraftBulkResolver
    MAX_DRAFTS = 500
    ACTIONS = %w[confirm ignore].freeze
    BulkResolutionError = Class.new(StandardError)
    Result = Struct.new(:success?, :drafts, :transactions, :errors, keyword_init: true)

    def initialize(household, draft_ids:, action:)
      @household = household
      @draft_ids = Array(draft_ids).map(&:to_i).select(&:positive?).uniq
      @action = action.to_s
    end

    def call
      validate_request!
      resolved_drafts = []
      transactions = []

      ApplicationRecord.transaction do
        drafts = household.transaction_drafts.where(id: draft_ids).order(:id).lock.to_a
        raise BulkResolutionError, "One or more transaction reviews could not be found" unless drafts.length == draft_ids.length
        raise BulkResolutionError, "Every selected transaction review must still be pending" unless drafts.all?(&:pending?)

        if action == "confirm"
          drafts.each do |draft|
            result = TransactionDraftConfirmer.new(draft, reconcile_import: false).call
            raise BulkResolutionError, result.errors.to_sentence unless result.success?

            resolved_drafts << result.draft
            transactions << result.transaction
          end
        else
          drafts.each do |draft|
            draft.update!(status: "ignored")
            resolved_drafts << draft
          end
        end
        reconcile_document_imports!(drafts)
      end

      Result.new(success?: true, drafts: resolved_drafts, transactions: transactions, errors: [])
    rescue BulkResolutionError, ArgumentError => e
      Result.new(success?: false, drafts: [], transactions: [], errors: [ e.message ])
    rescue ActiveRecord::RecordInvalid => e
      Result.new(success?: false, drafts: [], transactions: [], errors: e.record.errors.full_messages)
    end

    private

    attr_reader :household, :draft_ids, :action

    def validate_request!
      raise ArgumentError, "Unsupported bulk transaction action" unless action.in?(ACTIONS)
      raise ArgumentError, "Select at least one pending transaction review" if draft_ids.empty?
      raise ArgumentError, "Select no more than #{MAX_DRAFTS} transaction reviews at once" if draft_ids.length > MAX_DRAFTS
    end

    def reconcile_document_imports!(drafts)
      drafts.filter_map(&:financial_document_import).uniq(&:id).each do |document_import|
        DocumentImportStatusReconciler.new(document_import).call
      end
    end
  end
end
