require "test_helper"
require Rails.root.join("db/migrate/20261016120000_add_nothing_applied_document_import_status").to_s

# Review of #197 (M1): the migration only widens the status constraint and
# never rewrites existing imports or their approval audit fields.
class AddNothingAppliedDocumentImportStatusTest < ActiveSupport::TestCase
  test "up leaves every existing import row untouched" do
    user = User.create!(clerk_id: "nothing_applied_migration_#{SecureRandom.hex(6)}", email: "nothing-applied-migration-#{SecureRandom.hex(6)}@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Migration Household")
    applied_at = Time.zone.parse("2026-09-01 10:00:00")
    document_import = FinancialDocumentImport.create!(household: household, uploaded_by_user: user, document_kind: "statement", status: "applied",
      filename: "reviewed.pdf", content_type: "application/pdf", byte_size: 10, s3_key: "migration/#{SecureRandom.hex(6)}.pdf",
      applied_at: applied_at, applied_by_user: user)
    before = document_import.reload.attributes

    ActiveRecord::Migration.suppress_messages { AddNothingAppliedDocumentImportStatus.new.migrate(:up) }

    assert_equal before, document_import.reload.attributes
    assert_equal "applied", document_import.status
    assert_equal user.id, document_import.applied_by_user_id
  end
end
