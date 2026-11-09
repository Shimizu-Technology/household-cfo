# frozen_string_literal: true

class AddSetupSkippedFieldsToHouseholds < ActiveRecord::Migration[8.0]
  def change
    add_column :households, :setup_skipped_fields, :jsonb, default: [], null: false
  end
end
