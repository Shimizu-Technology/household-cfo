# frozen_string_literal: true

class RecordCoachListItemChoices < ActiveRecord::Migration[8.0]
  def change
    add_column :coach_persona_setup_proposals, :accepted_list_item_indexes, :jsonb
  end
end
