# Mia tells the coach when a participant asks to pause or leave the challenge.
# That is a support request of its own kind, not a setup problem.
class AllowLeaveChallengeSupportRequests < ActiveRecord::Migration[8.0]
  REASONS = %w[practice_numbers wrong_setup upload_problem other].freeze

  def up
    replace_reason_check(REASONS + %w[leave_challenge])
  end

  def down
    execute "UPDATE setup_support_requests SET reason = 'other' WHERE reason = 'leave_challenge'"
    replace_reason_check(REASONS)
  end

  private

  def replace_reason_check(reasons)
    remove_check_constraint :setup_support_requests, name: "setup_support_reason"
    add_check_constraint :setup_support_requests, "reason IN (#{reasons.map { |reason| "'#{reason}'" }.join(',')})", name: "setup_support_reason"
  end
end
