class MakeDocumentImportS3KeysUnique < ActiveRecord::Migration[8.1]
  INDEX_NAME = "index_financial_document_imports_on_s3_key"

  def up
    duplicate_groups = select_value(<<~SQL.squish).to_i
      SELECT COUNT(*)
      FROM (
        SELECT s3_key
        FROM financial_document_imports
        WHERE s3_key IS NOT NULL
        GROUP BY s3_key
        HAVING COUNT(*) > 1
      ) duplicate_s3_keys
    SQL
    if duplicate_groups.positive?
      raise ActiveRecord::MigrationError,
        "Cannot make document import S3 keys unique: #{duplicate_groups} duplicate key group(s) require manual reconciliation"
    end

    remove_index :financial_document_imports, name: INDEX_NAME if index_exists?(:financial_document_imports, :s3_key, name: INDEX_NAME)
    add_index :financial_document_imports, :s3_key, unique: true, where: "s3_key IS NOT NULL", name: INDEX_NAME
  end

  def down
    remove_index :financial_document_imports, name: INDEX_NAME if index_exists?(:financial_document_imports, :s3_key, name: INDEX_NAME)
    add_index :financial_document_imports, :s3_key, name: INDEX_NAME
  end
end
