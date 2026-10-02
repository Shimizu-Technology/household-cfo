# frozen_string_literal: true

class AddIngestionMethodToContentProvenance < ActiveRecord::Migration[8.1]
  def change
    %i[coach_content_item_draft_provenances coach_content_item_version_provenances].each do |table|
      add_column table, :source_ingestion_method, :string, null: false, default: "upload"
      add_check_constraint table, "source_ingestion_method IN ('upload', 'url_snapshot')",
        name: "#{table}_ingestion_method_valid"
    end
  end
end
