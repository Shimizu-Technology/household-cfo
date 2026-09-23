class MakeDocumentImportS3KeysUnique < ActiveRecord::Migration[8.1]
  def change
    remove_index :financial_document_imports, :s3_key
    add_index :financial_document_imports, :s3_key, unique: true, where: "s3_key IS NOT NULL"
  end
end
