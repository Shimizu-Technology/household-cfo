# frozen_string_literal: true

# Allows "nothing_applied": review finished (every value ignored, or nothing
# to review) and nothing from the document was saved. Expand-only: existing
# rows are never rewritten; the app writes the status going forward.
class AddNothingAppliedDocumentImportStatus < ActiveRecord::Migration[8.1]
  STATUSES = %w[uploaded processing needs_review applied partially_applied nothing_applied failed source_deleted].freeze
  PREVIOUS_STATUSES = (STATUSES - %w[nothing_applied]).freeze

  def up
    replace_status_constraint(STATUSES)
  end

  # Rolling back to code that does not know the status needs those rows in
  # a status it accepts; "applied" is what that code wrote for them.
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
