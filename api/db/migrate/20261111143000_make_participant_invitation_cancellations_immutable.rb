# frozen_string_literal: true

# A cancellation record is access history, and it is also what stops a cancelled person's account from being
# deleted. The model refuses edits, but plain SQL could still change or remove a row, so the table gets the same
# guard the other access and audit history tables use. The table is new and small, so adding the trigger only
# takes a brief lock.
class MakeParticipantInvitationCancellationsImmutable < ActiveRecord::Migration[8.1]
  TRIGGER = "participant_invitation_cancellations_immutable"
  GUARD = "source_review_facts_immutable()"

  def up
    raise "#{GUARD} is missing" if select_value("SELECT to_regprocedure('#{GUARD}')").blank?

    execute "DROP TRIGGER IF EXISTS #{TRIGGER} ON participant_invitation_cancellations"
    execute "CREATE TRIGGER #{TRIGGER} BEFORE UPDATE OR DELETE ON participant_invitation_cancellations FOR EACH ROW EXECUTE FUNCTION #{GUARD}"
  end

  def down
    execute "DROP TRIGGER IF EXISTS #{TRIGGER} ON participant_invitation_cancellations"
  end
end
