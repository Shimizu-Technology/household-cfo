# frozen_string_literal: true

class CreateCoachContentSourceUrlIntakeAttempts < ActiveRecord::Migration[8.1]
  def up
    create_table :coach_content_source_url_intake_attempts do |t|
      t.references :coach_content_source_url_intake,
        null: false,
        foreign_key: { on_delete: :cascade },
        index: { name: "idx_url_intake_attempts_intake" }
      t.timestamps
    end

    add_index :coach_content_source_url_intake_attempts, :created_at,
      name: "idx_url_intake_attempts_created_at"

    execute <<~SQL.squish
      INSERT INTO coach_content_source_url_intake_attempts
        (coach_content_source_url_intake_id, created_at, updated_at)
      SELECT id, created_at, created_at
      FROM coach_content_source_url_intakes
    SQL
  end

  def down
    drop_table :coach_content_source_url_intake_attempts
  end
end
