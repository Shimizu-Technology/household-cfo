require "test_helper"
require "timeout"
require_relative "../support/owned_test_database"
require_relative "../support/savings_daily_test_support"

class SavingsDailyConcurrencyTest < ActiveSupport::TestCase
  include SavingsDailyTestSupport
  self.use_transactional_tests = false

  setup do
    travel_to Date.new(2026, 11, 1).in_time_zone("Pacific/Guam").noon
    setup_savings_context
    @daily_category = @savings_household.budget_categories.create!(name: "Reviewed Food", stack_key: "discretionary", sort_order: 1)
  end

  teardown do
    clear_owned_daily_fixture
    travel_back
  end

  test "simultaneous approval retries publish one actual and one immutable purchase version" do
    with_daily_operations do
      savings_enroll
      draft = daily_stage
      # A retry sends the identical reviewed locks, even if its worker begins
      # after the winning approval committed and advanced the persisted draft.
      outcomes = concurrently([ true, true ]) { daily_approve(draft, token: "same daily approval") }
      assert outcomes.all? { |value| value.is_a?(HouseholdFinance::Operations::Runner::Result) }, outcomes.map(&:inspect).join("\n")
      assert_equal 1, outcomes.count(&:replayed?)
      assert_equal 1, SavingsDailyPurchaseVersion.where(savings_enrollment: @savings_enrollment).count
      assert_equal 1, @savings_household.household_transactions.count
      assert_equal 1, SavingsDailyLedger.find_by!(savings_enrollment: @savings_enrollment).sequence
    end
  end

  test "competing corrections publish only one replacement and preserve old canonical facts" do
    with_daily_operations do
      savings_enroll
      first = daily_approve(daily_stage).subject
      drafts = [ daily_stage(3000, purchase: first.savings_daily_purchase), daily_stage(4000, purchase: first.savings_daily_purchase) ]
      outcomes = concurrently(drafts.map(&:id)) { |id| daily_approve(SavingsDailyPurchaseDraft.find(id)) }
      assert_equal 1, outcomes.count { |value| value.is_a?(HouseholdFinance::Operations::Runner::Result) }
      assert_equal 1, outcomes.count { |value| value.is_a?(HouseholdFinance::Operations::Base::StaleOperation) }
      assert_equal 2, SavingsDailyPurchaseVersion.where(savings_enrollment: @savings_enrollment).count
      assert_equal 2, @savings_household.household_transactions.count
      assert_equal 1, @savings_household.household_transactions.where(status: "confirmed").count
      assert_equal 2500, first.household_transaction.reload.total_amount_cents
      assert_equal "ignored", first.household_transaction.status
    end
  end

  test "simultaneous checkpoint drafts cannot publish competing successors" do
    with_daily_operations do
      savings_enroll
      travel_to Date.new(2026, 11, 30).in_time_zone("Pacific/Guam").noon
      drafts = 2.times.map { checkpoint_stage(30) }
      outcomes = concurrently(drafts.map(&:id)) { |id| checkpoint_approve(SavingsCheckpointDraft.find(id)) }
      assert_equal 1, outcomes.count { |value| value.is_a?(SavingsCheckpointVersion) }
      assert_equal 1, outcomes.count { |value| value.is_a?(HouseholdFinance::Operations::Base::StaleOperation) }
      assert_equal 1, SavingsCheckpointVersion.where(savings_enrollment: @savings_enrollment).count
      assert_equal 1, SavingsCheckpoint.where(savings_enrollment: @savings_enrollment).count
    end
  end

  test "cohort hold committed before blocked daily approval leaves no expense or private approved version" do
    with_daily_operations do
      savings_enroll
      draft = daily_stage
      arrived, release = Queue.new, Queue.new
      holder = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Cohort.transaction do
            Cohort.lock.find(@savings_cohort.id).update!(savings_challenge_release_hold: true)
            arrived << true
            release.pop
          end
        end
      end
      Timeout.timeout(10) { arrived.pop }
      connection = ActiveRecord::Base.connection
      connection.execute("SET lock_timeout = '500ms'")
      assert_raises(ActiveRecord::LockWaitTimeout) { daily_approve(draft) }
      connection.execute("SET lock_timeout = DEFAULT")
      release << true
      holder.value
      assert_raises(SavingsChallenge::AccessPolicy::Unavailable) { daily_approve(draft) }
      assert_equal 0, SavingsDailyPurchaseVersion.where(savings_enrollment: @savings_enrollment).count
      assert_empty @savings_household.household_transactions
    ensure
      connection&.execute("SET lock_timeout = DEFAULT")
      release << true if holder&.alive?
      holder&.join(10)
    end
  end

  test "summary and daily GETs finish while a household writer is uncommitted" do
    with_daily_operations do
      savings_enroll
      savings_approve(savings_draft(101))
      daily_approve(daily_stage(2501))
      arrived, release = Queue.new, Queue.new
      writer = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          Household.find(@savings_household.id).with_lock do
            savings_approve(savings_draft(202))
            daily_approve(daily_stage(3503))
            arrived << true
            release.pop
          end
        end
      end
      Timeout.timeout(20) { arrived.pop }
      [ "/api/v1/savings_challenge", "/api/v1/savings_challenge/daily" ].each do |path|
        result = Timeout.timeout(20) { read_savings(path) }
        assert_equal 200, result[:status], result[:body].inspect
        assert_empty result[:sql].grep(/FOR UPDATE/i)
        assert_empty result[:sql].grep(/\A\s*(?:INSERT|UPDATE|DELETE)\b/i)
        if path.end_with?("daily")
          assert_equal 2501, result[:body].dig("day", "reported_spend_cents")
          assert_equal 1, result[:body].dig("day", "approved_purchase_count")
        else
          assert_equal 101, result[:body].dig("projection", "reported_cents")
        end
      end
    ensure
      release << true if writer&.alive?
      writer&.value
    end
  end

  test "summary and daily GETs keep one committed picture when approval commits during serialization" do
    with_daily_operations do
      savings_enroll
      savings_approve(savings_draft(101))
      daily_approve(daily_stage(2501))
      [ [ Api::V1::SavingsChallengesController, :challenge_data, "/api/v1/savings_challenge" ],
        [ Api::V1::SavingsDailyController, :context_day, "/api/v1/savings_challenge/daily" ] ].each do |klass, method, path|
        arrived, resume = Queue.new, Queue.new
        original = klass.instance_method(method)
        restore = stub_private_method(klass, method) do
          # The policy/enrollment reads have already established the snapshot.
          arrived << true
          Timeout.timeout(20) { resume.pop }
          original.bind_call(self)
        end
        before = savings_projection[:reported_cents]
        before_day = SavingsChallenge::Daily::DayProjection.new(@savings_enrollment, user: @savings_user, local_on: @savings_enrollment.local_today).call[:reported_spend_cents]
        reader = Thread.new { ApplicationRecord.connection_pool.with_connection { read_savings(path) } }
        Timeout.timeout(20) { arrived.pop }
        savings_approve(savings_draft(202))
        daily_approve(daily_stage(3503))
        resume << true
        result = Timeout.timeout(20) { reader.value }
        assert_equal 200, result[:status], result[:body].inspect
        assert_equal before, result[:body].dig("projection", "reported_cents") unless path.end_with?("daily")
        assert_equal before_day, result[:body].dig("day", "reported_spend_cents") if path.end_with?("daily")
        assert_empty result[:sql].grep(/FOR UPDATE/i)
      ensure
        resume << true if reader&.alive?
        reader&.join(20)
        restore&.call
      end
    end
  end

  test "revocation and release hold committed during a read discard its private response" do
    with_daily_operations do
      savings_enroll
      [ [ Api::V1::SavingsChallengesController, :challenge_data, "/api/v1/savings_challenge", :revoke ],
        [ Api::V1::SavingsDailyController, :context_day, "/api/v1/savings_challenge/daily", :hold ] ].each do |klass, method, path, mutation|
        arrived, resume = Queue.new, Queue.new
        original = klass.instance_method(method)
        restore = stub_private_method(klass, method) do
          body = original.bind_call(self)
          arrived << true
          Timeout.timeout(20) { resume.pop }
          body
        end
        reader = Thread.new { ApplicationRecord.connection_pool.with_connection { read_savings(path) } }
        Timeout.timeout(20) { arrived.pop }
        mutation == :revoke ? @savings_user.update!(invitation_status: "revoked") : @savings_cohort.update!(savings_challenge_release_hold: true)
        resume << true
        result = Timeout.timeout(20) { reader.value }
        assert_equal 403, result[:status], result[:body].inspect
        refute result[:body].key?("projection")
        refute result[:body].key?("day")
        @savings_user.update!(invitation_status: "accepted")
      ensure
        resume << true if reader&.alive?
        reader&.join(20)
        restore&.call
      end
    end
  end

  test "two concurrent first workspace GETs publish exactly one numeric annual plan" do
    with_daily_operations do
      savings_enroll
      arrived, release = Queue.new, Queue.new
      klass = HouseholdFinance::AnnualBudgetManager
      original = klass.instance_method(:complete_plan?)
      restore = stub_private_method(klass, :complete_plan?) do
        complete = original.bind_call(self)
        unless complete || Thread.current[:w3_initial_plan_checked]
          Thread.current[:w3_initial_plan_checked] = true
          arrived << true
          Timeout.timeout(20) { release.pop }
        end
        complete
      end
      readers = 2.times.map { Thread.new { ApplicationRecord.connection_pool.with_connection { read_savings("/api/v1/workspace") } } }
      Timeout.timeout(20) { 2.times { arrived.pop } }
      2.times { release << true }
      responses = readers.map { |reader| Timeout.timeout(20) { reader.value } }
      assert_equal [ 200, 200 ], responses.map { |result| result[:status] }, responses.inspect
      year = @savings_household.budget_years.sole
      ids = year.budget_periods.order(:starts_on).pluck(:id)
      assert_equal 12, ids.size
      responses.each do |result|
        assert_equal ids, result[:body].dig("budget", "annual_plan", "months").pluck("id")
        assert result[:body].dig("budget", "annual_plan", "months").all? { |month| month["id"].is_a?(Integer) }
      end
    ensure
      2.times { release << true }
      readers&.each { |reader| reader.join(20) }
      restore&.call
    end
  end

  private

  def read_savings(path)
    session = ActionDispatch::Integration::Session.new(Rails.application)
    sql = []
    owner_thread = Thread.current
    subscriber = lambda do |_name, _start, _finish, _id, payload|
      sql << payload[:sql] if Thread.current == owner_thread && payload[:name] != "SCHEMA" && !payload[:cached]
    end
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      session.get path, headers: { "Authorization" => "Bearer test_token_#{@savings_user.id}", "X-Cohort-Id" => @savings_cohort.id.to_s }
    end
    { status: session.response.status, body: session.response.parsed_body, sql: sql }
  end

  def stub_private_method(klass, name, &body)
    original = klass.instance_method(name)
    klass.send(:define_method, name, &body)
    klass.send(:private, name)
    -> { klass.send(:define_method, name, original); klass.send(:private, name) }
  end

  def concurrently(values)
    ready, release = Queue.new, Queue.new
    threads = values.map do |value|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          yield value
        rescue StandardError => error
          error
        end
      end
    end
    Timeout.timeout(10) { values.size.times { ready.pop } }
    values.size.times { release << true }
    threads.each { |thread| thread.join(20) }
    assert threads.none?(&:alive?), "Private daily operations did not finish within the bounded test"
    threads.map(&:value)
  ensure
    values.size.times { release << true }
    threads&.each { |thread| thread.join(1) }
  end

  def clear_owned_daily_fixture
    connection = ActiveRecord::Base.connection
    OwnedTestDatabase.assert!(connection: connection)
    daily_tables = %w[savings_daily_ledgers savings_daily_purchases savings_daily_purchase_drafts savings_daily_purchase_versions savings_daily_reflections savings_daily_reflection_versions savings_daily_check_ins savings_daily_check_in_versions savings_checkpoints savings_checkpoint_drafts savings_checkpoint_versions]
    savings_tables = %w[savings_enrollments savings_entries savings_entry_versions savings_plan_versions savings_zero_attestations savings_entry_drafts savings_plan_drafts]
    release_tables = %w[cohorts cohort_release_activation_events cohort_releases cohort_experience_versions cohort_experience_publication_events]
    tables = daily_tables + savings_tables + release_tables
    enrollment_ids = SavingsEnrollment.where(cohort_id: @savings_cohort.id).pluck(:id)
    ApplicationRecord.transaction do
      tables.each { |table| connection.execute("ALTER TABLE #{table} DISABLE TRIGGER USER") }
      %w[savings_daily_purchases savings_daily_reflections savings_daily_check_ins savings_checkpoints].each do |table|
        connection.execute("UPDATE #{table} SET current_version_id = NULL WHERE savings_enrollment_id IN (#{enrollment_ids.join(',')})") if enrollment_ids.any?
      end
      %w[savings_daily_purchase_drafts savings_checkpoint_drafts savings_checkpoint_versions savings_daily_check_in_versions savings_daily_reflection_versions savings_daily_reflections savings_daily_purchase_versions savings_daily_check_ins savings_checkpoints savings_daily_purchases savings_daily_ledgers].each do |table|
        table.classify.constantize.where(savings_enrollment_id: enrollment_ids).delete_all
      end
      SavingsEnrollment.where(id: enrollment_ids).update_all(current_accepted_plan_version_id: nil)
      SavingsEntry.where(savings_enrollment_id: enrollment_ids).update_all(current_approved_version_id: nil)
      %w[SavingsEntryDraft SavingsPlanDraft SavingsEntryVersion SavingsPlanVersion SavingsZeroAttestation SavingsEntry SavingsEnrollment].each do |name|
        model = name.constantize
        scope = if name == "SavingsEnrollment"
          model.where(id: enrollment_ids)
        elsif name == "SavingsEntryDraft"
          model.where(savings_entry_id: SavingsEntry.where(savings_enrollment_id: enrollment_ids).select(:id))
        else
          model.where(savings_enrollment_id: enrollment_ids)
        end
        scope.delete_all
      end
      @savings_cohort.update_columns(active_cohort_release_id: nil)
      CohortReleaseActivationEvent.where(cohort_id: @savings_cohort.id).delete_all
      CohortRelease.where(cohort_id: @savings_cohort.id).delete_all
      configuration = @savings_cohort.cohort_experience_configuration
      configuration.update_columns(current_published_version_id: nil)
      CohortExperiencePublicationEvent.where(cohort_experience_configuration_id: configuration.id).delete_all
      CohortExperienceVersion.where(cohort_experience_configuration_id: configuration.id).delete_all
      tables.each { |table| connection.execute("ALTER TABLE #{table} ENABLE TRIGGER USER") }
    end
    CohortMembership.where(cohort_id: @savings_cohort.id).delete_all
    CohortExperienceConfiguration.where(cohort_id: @savings_cohort.id).delete_all
    Cohort.where(id: @savings_cohort.id).delete_all
    @savings_household.destroy!
    delete_empty_coach_workspaces_for_users([ @savings_user.id, @savings_owner.id ])
    @savings_user.reload.destroy!
    @savings_owner.reload.destroy!
  end
end
