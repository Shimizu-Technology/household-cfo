require "timeout"

database = ActiveRecord::Base.connection_db_config.database
unless Rails.env.test? && database == ENV.fetch("SETUP_HELP_CONCURRENCY_DATABASE") && database.end_with?("_test")
  raise "This script requires its exact explicitly owned disposable test database"
end

def fixture
  id = SecureRandom.hex(8)
  user = User.create!(clerk_id: "setup-race-#{id}", email: "setup-race-#{id}@example.com", role: "participant", invitation_status: "accepted")
  household = HouseholdFinance::WorkspaceResolver.new(user).household
  admin = User.create!(clerk_id: "setup-race-admin-#{id}", email: "setup-race-admin-#{id}@example.com", role: "admin", invitation_status: "accepted")
  [ household, user, admin ]
end

def simultaneous(count)
  ready, release, output = Queue.new, Queue.new, Queue.new
  threads = count.times.map do |index|
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ready << true
        release.pop
        output << yield(index)
      rescue StandardError => error
        output << error
      end
    end
  end
  Timeout.timeout(20) do
    count.times { ready.pop }
    count.times { release << true }
    threads.each(&:join)
  end
  count.times.map { output.pop }
ensure
  count.times { release << true } if release
  threads&.each { |thread| thread.join(1) }
end

household, participant, admin = fixture
outcomes = simultaneous(2) do
  SetupHelp::Participant.new(Household.find(household.id), user: User.find(participant.id))
    .create_request(reason: "practice_numbers", share_metadata: true, idempotency_key: "same-request")[:request][:id]
end
raise "Concurrent request replay failed" unless outcomes.uniq.length == 1 && outcomes.none? { |item| item.is_a?(Exception) }
raise "Concurrent request creation duplicated records" unless household.setup_support_requests.count == 1 && SetupHelpRequestKey.where(household: household).count == 1
request_id = outcomes.first
outcomes = simultaneous(2) do
  SetupHelp::Staff.new(user: User.find(admin.id)).transition(id: request_id, action: "prepare", expected_lock_version: 0)
end
raise "Concurrent preparation did not preserve exact request version" unless outcomes.count { |item| item.is_a?(Hash) } == 1 && outcomes.count { |item| item.is_a?(SetupHelp::Stale) } == 1
request = SetupSupportRequest.find(request_id)
raise "Concurrent preparation published multiple reviews" unless household.financial_restart_reviews.where(purpose: "supported_setup").count == 1
outcomes = simultaneous(2) do
  SetupHelp::Restart.new(Household.find(household.id), user: User.find(participant.id), request_id: request.id)
    .apply(review_id: request.financial_restart_review_id, confirmation: "START OVER")
end
raise "Concurrent receipt recovery failed" unless outcomes.all? { |item| item.is_a?(Hash) && item.dig(:review, :status) == "applied" }
raise "Concurrent confirmation restarted twice" unless household.reload.financial_generation == 1 && household.household_audit_events.where(event_type: "financial_restart.applied").count == 1

5.times do
  household, participant, admin = fixture
  request = SetupHelp::Participant.new(household, user: participant).create_request(reason: "wrong_setup", share_metadata: true, idempotency_key: "race")[:request]
  ready = SetupHelp::Staff.new(user: admin).transition(id: request[:id], action: "prepare", expected_lock_version: 0)[:request]
  outcomes = simultaneous(2) do |index|
    current_household = Household.find(household.id)
    user = User.find(participant.id)
    if index.zero?
      SetupHelp::Participant.new(current_household, user: user).cancel_request(id: request[:id], expected_lock_version: ready[:lock_version])
    else
      SetupHelp::Restart.new(current_household, user: user, request_id: request[:id]).apply(review_id: ready[:review_id], confirmation: "START OVER")
    end
  end
  saved = SetupSupportRequest.find(request[:id])
  raise "Concurrent cancel and apply both succeeded" unless outcomes.count { |item| item.is_a?(Hash) } == 1
  raise "Concurrent cancel and apply lost request state" unless saved.status.in?(%w[applied canceled])
  raise "Cancellation changed finances" if saved.status == "canceled" && household.reload.financial_generation != 0
  raise "Successful confirmation missed rollover" if saved.status == "applied" && household.reload.financial_generation != 1
end

# Concurrent requests after an ordinary-program rejoin retire the old lifecycle once.
household, participant, admin = fixture
cohort = Cohort.create!(name: "Setup rejoin race #{SecureRandom.hex(4)}", status: "active", created_by_user: admin)
member = cohort.cohort_memberships.create!(user: participant, role: "participant")
old = SetupHelp::Participant.new(household, user: participant, cohort_membership: member)
  .create_request(reason: "wrong_setup", share_metadata: true, idempotency_key: "before-rejoin")[:request]
prepared = SetupHelp::Staff.new(user: admin).transition(id: old[:id], action: "prepare", expected_lock_version: 0)[:request]
member.destroy!
replacement = cohort.cohort_memberships.create!(user: participant, role: "participant")
outcomes = simultaneous(2) do |index|
  SetupHelp::Participant.new(Household.find(household.id), user: User.find(participant.id), cohort_membership: CohortMembership.find(replacement.id))
    .create_request(reason: "wrong_setup", share_metadata: true, idempotency_key: "after-rejoin-#{index}")[:request][:id]
end
raise "Rejoined concurrent requests failed or duplicated" unless outcomes.none? { |item| item.is_a?(Exception) } && outcomes.uniq.length == 1 && outcomes.first != old[:id]
raise "Old review was retargeted or retained live" unless SetupSupportRequest.find(old[:id]).status == "canceled" && FinancialRestartReview.find(prepared[:review_id]).status == "canceled"
raise "Concurrent retirement duplicated audit" unless household.household_audit_events.where(event_type: "setup_support.retired").count == 1

# Let a financial save commit while the self restart waits for the same household.
household, participant, = fixture
review = SetupHelp::Restart.new(household, user: participant).preview[:review]
entered, release, started, outcome = Queue.new, Queue.new, Queue.new, Queue.new
holder = Thread.new do
  ActiveRecord::Base.connection_pool.with_connection do
    Household.find(household.id).with_lock do |*|
      Household.find(household.id).income_sources.create!(label: "Saved real pay", amount_cents: 100_000, cadence: "monthly", source_type: "job")
      entered << true
      release.pop
    end
  end
end
Timeout.timeout(10) { entered.pop }
applicant = Thread.new do
  ActiveRecord::Base.connection_pool.with_connection do |connection|
    started << connection.select_value("SELECT pg_backend_pid()")
    outcome << SetupHelp::Restart.new(Household.find(household.id), user: User.find(participant.id)).apply(review_id: review[:id], confirmation: "START OVER")
  rescue StandardError => error
    outcome << error
  end
end
pid = Timeout.timeout(10) { started.pop }
Timeout.timeout(10) do
  loop do
    waiting = ActiveRecord::Base.connection.select_value("SELECT wait_event_type = 'Lock' FROM pg_stat_activity WHERE pid = #{Integer(pid)}")
    break if waiting
    sleep 0.01
  end
end
release << true
holder.join(10)
applicant.join(10)
raise "Concurrent saved facts did not block self restart" unless outcome.pop.is_a?(SetupHelp::Error) && household.reload.financial_generation == 0 && household.income_sources.count == 1

puts "Setup help concurrency: duplicate create, exact preparation, duplicate confirmation, five cancel/apply races, membership rejoin retirement, and blocked self restart after financial save passed."
