# Mia tells the coach when a participant asks to pause or leave the challenge.
# That is a support request of its own kind, not a setup problem.
class AllowLeaveChallengeSupportRequests < ActiveRecord::Migration[8.0]
  REASONS = %w[practice_numbers wrong_setup upload_problem other].freeze

  def up
    replace_reason_check(REASONS + %w[leave_challenge])
    replace_active_indexes(separate_leave: true)
    replace_status_check(%w[requested in_review ready applied canceled declined acknowledged])
    add_check_constraint :setup_support_requests,
      "reason <> 'leave_challenge' OR (financial_restart_review_id IS NULL AND prepared_by_user_id IS NULL AND status NOT IN ('ready', 'applied'))",
      name: "setup_support_leave_no_restart"
  end

  def down
    # Restoring the old uniqueness rule must not discard outstanding support work.
    duplicates = select_value(<<~SQL)
      SELECT COUNT(*) FROM (
        SELECT 1 FROM setup_support_requests WHERE status IN ('requested', 'in_review', 'ready')
        GROUP BY household_id, requested_by_user_id, cohort_id HAVING COUNT(*) > 1
      ) active
    SQL
    raise ActiveRecord::IrreversibleMigration, "Resolve separate active support tickets before rolling back." if duplicates.to_i.positive?

    remove_check_constraint :setup_support_requests, name: "setup_support_leave_no_restart"
    replace_active_indexes(separate_leave: false)
    execute "UPDATE setup_support_requests SET status = 'declined' WHERE status = 'acknowledged'"
    replace_status_check(%w[requested in_review ready applied canceled declined])
    execute "UPDATE setup_support_requests SET reason = 'other' WHERE reason = 'leave_challenge'"
    replace_reason_check(REASONS)
  end

  private

  def replace_active_indexes(separate_leave:)
    %w[setup_support_active_program setup_support_active_personal setup_support_leave_program setup_support_leave_personal].each do |name|
      remove_index :setup_support_requests, name: name, if_exists: true
    end
    active = "status IN ('requested', 'in_review', 'ready')"
    columns = [ :household_id, :requested_by_user_id ]
    setup = separate_leave ? " AND reason <> 'leave_challenge'" : ""
    add_index :setup_support_requests, columns + [ :cohort_id ], unique: true,
      where: "cohort_id IS NOT NULL AND #{active}#{setup}", name: "setup_support_active_program"
    add_index :setup_support_requests, columns, unique: true,
      where: "cohort_id IS NULL AND #{active}#{setup}", name: "setup_support_active_personal"
    if separate_leave
      add_index :setup_support_requests, columns + [ :cohort_id ], unique: true,
        where: "cohort_id IS NOT NULL AND #{active} AND reason = 'leave_challenge'", name: "setup_support_leave_program"
      add_index :setup_support_requests, columns, unique: true,
        where: "cohort_id IS NULL AND #{active} AND reason = 'leave_challenge'", name: "setup_support_leave_personal"
    end
  end

  def replace_status_check(statuses)
    remove_check_constraint :setup_support_requests, name: "setup_support_status"
    add_check_constraint :setup_support_requests, "status IN (#{statuses.map { |status| "'#{status}'" }.join(',')})", name: "setup_support_status"
  end

  def replace_reason_check(reasons)
    remove_check_constraint :setup_support_requests, name: "setup_support_reason"
    add_check_constraint :setup_support_requests, "reason IN (#{reasons.map { |reason| "'#{reason}'" }.join(',')})", name: "setup_support_reason"
  end
end
