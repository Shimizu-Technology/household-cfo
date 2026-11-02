# frozen_string_literal: true

class ExpandCoachTranscriptMessages < ActiveRecord::Migration[8.0]
  def up
    remove_check_constraint :coach_persona_setup_turns, name: "persona_setup_turns_user_message_length"
    add_check_constraint :coach_persona_setup_turns, "char_length(user_message) >= 1 AND char_length(user_message) <= 24000", name: "persona_setup_turns_user_message_length"
  end

  def down
    # Large existing transcript messages must be preserved, never truncated during rollback.
    raise ActiveRecord::IrreversibleMigration
  end
end
