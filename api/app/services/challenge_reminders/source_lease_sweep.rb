module ChallengeReminders
  class SourceLeaseSweep
    MAX_BATCH = 100
    def call(limit: MAX_BATCH)
      # Correlated NOT EXISTS honors the latest explicit unrevoked use. Sources
      # with no challenge lease retain their earlier retention policy.
      sources = FinancialDocumentImport.where(source_deleted_at: nil)
        .where("EXISTS (SELECT 1 FROM financial_source_uses u WHERE u.financial_document_import_id = financial_document_imports.id)")
        .where("NOT EXISTS (SELECT 1 FROM financial_source_uses u WHERE u.financial_document_import_id = financial_document_imports.id AND u.revoked_at IS NULL AND u.expires_at > ?)", Time.current)
      sources.order(:id).limit(Integer(limit).clamp(1, MAX_BATCH)).each do |source|
        ChallengePrivacy::SourceRetention.new(source.household, user: nil).expire!(source)
      end
    end
  end
end
