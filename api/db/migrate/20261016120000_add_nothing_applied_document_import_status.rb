# frozen_string_literal: true

# An import whose every value was ignored, or that produced nothing to review
# (a non-financial photo), used to finish as "applied", which Mia's context
# treats as an approved source. "nothing_applied" records that review is
# finished and nothing from the document was saved.
class AddNothingAppliedDocumentImportStatus < ActiveRecord::Migration[8.1]
  STATUSES = %w[uploaded processing needs_review applied partially_applied nothing_applied failed source_deleted].freeze
  PREVIOUS_STATUSES = (STATUSES - %w[nothing_applied]).freeze

  def up
    replace_status_constraint(STATUSES)
    execute <<~SQL
      UPDATE financial_document_imports
      SET status = 'nothing_applied', applied_at = NULL, applied_by_user_id = NULL, updated_at = NOW()
      WHERE status = 'applied'
        AND NOT EXISTS (
          SELECT 1 FROM financial_document_import_items items
          WHERE items.financial_document_import_id = financial_document_imports.id AND items.applied_at IS NOT NULL
        )
        AND NOT EXISTS (
          SELECT 1 FROM transaction_drafts drafts
          WHERE drafts.financial_document_import_id = financial_document_imports.id
            AND drafts.status IN ('confirmed', 'corrected', 'matched')
        )
    SQL
  end

  def down
    execute "UPDATE financial_document_imports SET status = 'applied' WHERE status = 'nothing_applied'"
    replace_status_constraint(PREVIOUS_STATUSES)
  end

  private

  def replace_status_constraint(statuses)
    remove_check_constraint :financial_document_imports, name: "financial_document_imports_status_valid"
    add_check_constraint :financial_document_imports,
      "status IN (#{statuses.map { |status| connection.quote(status) }.join(', ')})",
      name: "financial_document_imports_status_valid"
  end
end
