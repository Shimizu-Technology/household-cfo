# Run after the ordinary suite against an explicitly named disposable database.
# This writes synthetic immutable records; drop the database after verification.
database = ActiveRecord::Base.connection.current_database
raise "Use an explicitly named disposable test database" unless Rails.env.test? &&
  ENV["BASELINE_CONCURRENCY_DISPOSABLE_DATABASE"] == database && database.end_with?("_test")

user = User.create!(clerk_id: "baseline-concurrency-#{SecureRandom.hex(8)}", email: "baseline-concurrency-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
household = Household.create!(created_by_user: user, name: "Synthetic simultaneous baseline approval")
household.household_memberships.create!(user: user, role: "owner")
request = { window_start_on: "2026-07-01", window_end_on: "2026-07-31", revision_ids: [], tracked_account_ids: [],
  household_scope_attested: false, cash_coverage: "unknown", missing_accounts: [ "No statements supplied in this synthetic manual case" ] }
preview = FinancialBaselines::Preview.new(household, user: user).call(request)
input = { request: request, coverage_status: "manual", base_version_id: nil, base_lock_version: 0,
  expected_preview_digest: preview[:digest], reason: "Participant approved a limited manual baseline with unknown financial observations" }
prepared = 2.times.map { HouseholdFinance::Operations::Baseline::Approve.new(household, user: user).prepare(input) }
ready, release, outcomes = Queue.new, Queue.new, Queue.new
threads = prepared.map do |operation_request|
  Thread.new do
    ActiveRecord::Base.connection_pool.with_connection do
      operation = HouseholdFinance::Operations::Baseline::Approve.new(Household.find(household.id), user: User.find(user.id))
      ready << true
      release.pop
      begin
        ApplicationRecord.transaction do
          result = operation.execute!(operation_request, source: "manual")
          operation.send(:verify_after!, operation_request.predicted_after_snapshot, operation.after_snapshot(result, operation_request))
        end
        outcomes << "approved"
      rescue HouseholdFinance::Operations::Base::StaleOperation
        outcomes << "stale_blocked"
      end
    end
  end
end
2.times { ready.pop }
2.times { release << true }
threads.each(&:value)
results = 2.times.map { outcomes.pop }.sort
head = FinancialBaselineHead.find_by!(household: household, participant_user: user)
versions = FinancialBaselineVersion.where(household: household).count
raise "Simultaneous baseline approval replaced an unreviewed head" unless results == %w[approved stale_blocked] && versions == 1 && head.approved_version.version_number == 1
raise "An empty manual baseline manufactured known zero spending" if head.approved_version.snapshot["observed_spending_known"]
puts({ check: "simultaneous_baseline_approval", outcomes: results, approved_versions: versions, current_version_number: head.approved_version.version_number, spending_known: false }.to_json)
