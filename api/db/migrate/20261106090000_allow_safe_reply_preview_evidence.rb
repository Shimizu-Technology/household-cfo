# frozen_string_literal: true

class AllowSafeReplyPreviewEvidence < ActiveRecord::Migration[8.0]
  def up
    replace_source_constraint("response_source IN ('live_model', 'deterministic_fallback', 'deterministic_safety')")
  end

  def down
    # Existing immutable safe-reply evidence must not be deleted to roll back.
    raise ActiveRecord::IrreversibleMigration, "Safe reply previews may already be sealed into published versions"
  end

  private

  def replace_source_constraint(source)
    remove_check_constraint :coach_persona_behavioral_preview_evidences, name: "persona_behavioral_previews_bounded"
    add_check_constraint :coach_persona_behavioral_preview_evidences,
      "char_length(prompt) BETWEEN 1 AND 2000 AND char_length(output) BETWEEN 1 AND 4000 AND char_length(model_identifier) BETWEEN 1 AND 200 AND #{source} AND privacy_scope = 'no_saved_participant_or_household_data'",
      name: "persona_behavioral_previews_bounded"
  end
end
