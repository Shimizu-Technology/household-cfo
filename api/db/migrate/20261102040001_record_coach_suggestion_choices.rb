# frozen_string_literal: true

class RecordCoachSuggestionChoices < ActiveRecord::Migration[8.0]
  def change
    add_column :coach_persona_setup_proposals, :accepted_operation_indexes, :jsonb
  end
end
