require "test_helper"
require "timeout"
require_relative "../support/coach_launch_test_helper"

# No enclosing test transaction: success here means PostgreSQL ran COMMIT and
# every deferred trigger, not merely that the publisher returned a result.
class CoachLaunchesCommitTest < ActiveSupport::TestCase
  include CoachLaunchTestHelper
  self.use_transactional_tests = false

  setup do
    prepare_launch
    @participants = @groups.map do |cohort|
      user = persona_user(role: "participant")
      user.cohort_memberships.create!(cohort:, role: "participant")
      user
    end
    @review = build_review
  end

  teardown do
    cleanup_launch_records
  end

  test "first launch and later brand tools and voice updates commit for two populated groups and replay" do
    assert_equal 0, ActiveRecord::Base.connection.open_transactions
    first = publish
    assert_equal 2, first.fetch("groups").length
    @groups.each { |c| assert c.reload.active_cohort_release_id }
    previous = @groups.map(&:active_cohort_release_id)

    brand = @workspace.workspace_brand_configuration.reload
    brand.update!(draft_config: brand.draft_config.merge("product_name" => "A changed program"))
    @groups.each do |cohort|
      tools = cohort.cohort_experience_configuration.reload
      tools.update!(draft_config: tools.draft_config.deep_merge("optional_modules" => { "wealth" => false }))
    end
    draft = @persona.reload.draft_config.deep_dup
    draft["identity"]["assistant_name"] = "Updated Mia"
    Mia::PersonaDraftUpdater.new(persona: @persona, actor: @owner, workspace: @workspace).call!(
      expected_draft_revision: @persona.draft_revision, description: @persona.description, draft_config: draft)
    Mia::PersonaPublisher.new(persona: @persona, actor: @owner).preview!(expected_draft_revision: @persona.reload.draft_revision)
    persona_release_evidence(@persona, actor: @owner)
    @review = build_review
    result = publish(request_key: "second-launch")
    assert_equal 0, ActiveRecord::Base.connection.open_transactions
    @groups.each_with_index do |cohort, index|
      release = cohort.reload.active_cohort_release
      refute_equal previous[index], release.id
      assert_equal "Updated Mia", release.coach_persona_version.config.dig("identity", "assistant_name")
      assert_equal "A changed program", release.workspace_brand_version.config["product_name"]
      assert_equal false, release.cohort_experience_version.config.dig("optional_modules", "wealth")
      assert_equal "completed", cohort.cohort_rollouts.sole.status
      assert_equal %w[planned activated completed], cohort.cohort_rollouts.sole.transitions.order(:id).pluck(:event_type)
      assert_equal 2, cohort.cohort_release_activation_events.count
      assert_equal 1, cohort.cohort_release_exposures.where(event_type: "wave").count
    end
    assert_no_difference [ "CohortRelease.count", "CoachLaunchReceipt.count", "CohortReleaseActivationEvent.count", "CoachOperationExecution.count" ] do
      assert_equal result, publish(request_key: "second-launch")
    end
  end

  test "late failure while updating second live group rolls back first group and all staged publications at commit" do
    publish
    previous = @groups.map { |c| c.reload.active_cohort_release_id }
    brand = @workspace.workspace_brand_configuration.reload
    brand.update!(draft_config: brand.draft_config.merge("product_name" => "Atomic later change"))
    @review = build_review
    extra = Cohort.create!(name: "Extra group", status: "active", created_by_user: @owner, coach_workspace: @workspace)
    @participants.last.cohort_memberships.create!(cohort: extra, role: "participant")
    assert_no_difference [ "CohortRelease.count", "WorkspaceBrandVersion.count", "CohortReleaseExposure.count", "CoachLaunchReceipt.count" ] do
      error = assert_raises(CoachLaunches::Publisher::Conflict) { publish(request_key: "failed-update") }
      assert_includes error.message, CohortRollouts::Contract.participant_display_name(@participants.last)
      assert_includes error.message, "Participant access"
    end
    assert_equal previous, @groups.map { |c| c.reload.active_cohort_release_id }
    assert_equal 0, CohortRollout.where(cohort_id: @groups.map(&:id)).count
    @participants.last.cohort_memberships.find_by!(cohort: extra).destroy!
    publish(request_key: "failed-update")
    assert @groups.each_with_index.all? { |c, i| c.reload.active_cohort_release_id != previous[i] }
  end

  test "resolution waits for the launch commit and returns its live receipt" do
    written = Queue.new
    commit = Queue.new
    checking = Queue.new
    results = Queue.new
    launch_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        CoachLaunchReceipt.transaction do
          result = publish
          written << result
          commit.pop
        end
      end
    rescue StandardError => error
      results << error
    end
    # This bounds fixture/publication setup, not the assertion that resolution
    # stays blocked until COMMIT. Loaded QA hosts can spend over 20s publishing.
    expected = Timeout.timeout(180) { written.pop }
    resolver_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        checking << true
        results << CoachLaunches::Publisher.new(persona: @persona, actor: @owner, review: @review, request_key: "one-launch").resolve!
      end
    rescue StandardError => error
      results << error
    end
    Timeout.timeout(5) { checking.pop }
    assert_raises(Timeout::Error) { Timeout.timeout(0.1) { results.pop } }
    commit << true
    launch_thread.join(180)
    resolver_thread.join(180)
    refute launch_thread.alive?
    refute resolver_thread.alive?
    assert_equal({ status: "live", launch: expected }, Timeout.timeout(5) { results.pop })
  ensure
    commit << true if commit
    launch_thread&.join(180)
    resolver_thread&.join(180)
  end

  test "early plan validation still rejects forged operation snapshots and rolls back the complete update" do
    publish
    previous = @groups.map { |c| c.reload.active_cohort_release_id }
    brand = @workspace.workspace_brand_configuration.reload
    brand.update!(draft_config: brand.draft_config.merge("product_name" => "Untrusted evidence"))
    @review = build_review
    original = CoachOperationExecution.instance_method(:save!)
    CoachOperationExecution.define_method(:save!) do |*args, **options|
      if operation_key == "cohort.rollout.plan"
        self.before_snapshot = before_snapshot.merge("active_release_id" => 0)
        self.before_snapshot_digest = CoachOperations::Contract.digest(before_snapshot)
        # Deliberately bypass model validation to exercise the DB constraint.
        return original.bind_call(self, *args, **options.merge(validate: false))
      end
      original.bind_call(self, *args, **options)
    end
    assert_no_difference [ "CoachLaunchReceipt.count", "CohortRelease.count", "WorkspaceBrandVersion.count", "CohortReleaseExposure.count" ] do
      error = assert_raises(ActiveRecord::StatementInvalid) { publish(request_key: "forged-plan") }
      assert_includes error.message, "v2 rollout snapshots do not match runtime evidence"
    end
    assert_equal previous, @groups.map { |c| c.reload.active_cohort_release_id }
  ensure
    CoachOperationExecution.define_method(:save!, original) if original
  end

  test "pending and revoked invitees do not block real committed updates and retain honest readiness evidence" do
    @participants.first.update!(invitation_status: "pending")
    @participants.last.update!(invitation_status: "revoked")
    publish
    accepted = persona_user(role: "participant")
    @participants << accepted
    accepted.cohort_memberships.create!(cohort: @groups.first, role: "participant")
    brand = @workspace.workspace_brand_configuration.reload
    brand.update!(draft_config: brand.draft_config.merge("product_name" => "Latest invitation program"))
    @review = build_review
    result = publish(request_key: "pending-update")
    assert_equal 2, result.fetch("groups").length
    assert_equal %w[awaiting_acceptance revoked], result.fetch("groups").flat_map { |g| g.fetch("deferred_participants").pluck("state") }
    assert_equal result, CoachLaunchReceipt.find_by!(request_key: "pending-update").result
    @groups.each do |cohort|
      rollout = cohort.cohort_rollouts.sole
      assert_equal "completed", rollout.status
      assert cohort.reload.active_cohort_release.integrity_report.fetch(:valid)
      states = CohortRollouts::Contract.readiness_snapshot(cohort:).fetch("participants")
      state = states.find { |p| p["user_id"] == @participants[@groups.index(cohort)].id }.fetch("state")
      assert_equal cohort == @groups.first ? "awaiting_acceptance" : "revoked", state
      assert_equal "Latest invitation program", cohort.reload.active_cohort_release.workspace_brand_version.config["product_name"]
    end
    @participants.first.update!(invitation_status: "accepted")
    assert_equal @groups.first.active_cohort_release_id,
      Mia::ParticipantRuntimeResolver.new(user: @participants.first).call.release.id
  end

  test "accepted participant without a linked sign-in still blocks and rolls back every group" do
    publish
    previous = @groups.map { |c| c.reload.active_cohort_release_id }
    @participants.last.update!(clerk_id: "pending_unlinked_#{@participants.last.id}", first_name: "Maria")
    brand = @workspace.workspace_brand_configuration.reload
    brand.update!(draft_config: brand.draft_config.merge("product_name" => "Blocked update"))
    @review = build_review
    assert_no_difference [ "CohortRelease.count", "WorkspaceBrandVersion.count", "CohortReleaseExposure.count", "CoachLaunchReceipt.count" ] do
      error = assert_raises(CohortRollouts::StateMachine::Ineligible) { publish(request_key: "unlinked-update") }
      assert_includes error.message, "Maria needs to finish setting up their sign-in"
    end
    assert_equal previous, @groups.map { |c| c.reload.active_cohort_release_id }
  end

  test "nameless sign-in blocker uses plain email-free wording" do
    publish
    @participants.last.update!(clerk_id: "pending_nameless_#{@participants.last.id}", first_name: nil, last_name: nil)
    brand = @workspace.workspace_brand_configuration.reload
    brand.update!(draft_config: brand.draft_config.merge("product_name" => "Nameless blocked update"))
    @review = build_review
    error = assert_raises(CohortRollouts::StateMachine::Ineligible) { publish(request_key: "nameless-update") }
    assert_includes error.message, "Someone in this group needs to finish setting up their sign-in"
    refute_includes error.message, @participants.last.email
    refute_includes error.message, "Participant #{@participants.last.id}"
  end

  private

  def cleanup_launch_records
    return unless @workspace

    # Only this test's named workspace/users and their FK descendants. Immutable
    # audit rows cannot be destroyed through application APIs. Disable triggers
    # solely for fixture deletion; all launches above use the real constraints.
    connection = ActiveRecord::Base.connection
    owned = { "coach_workspaces" => [ @workspace.id ], "users" => [ @owner.id, *@participants&.map(&:id) ] }
    relations = connection.tables.flat_map { |table| connection.foreign_keys(table) }.reject { |fk| fk.column.is_a?(Array) }
    loop do
      changed = false
      relations.each do |fk|
        parent_ids = owned[fk.to_table]
        next if parent_ids.blank?

        table = connection.quote_table_name(fk.from_table)
        column = connection.quote_column_name(fk.column)
        ids = connection.select_values("SELECT id FROM #{table} WHERE #{column} IN (#{parent_ids.map(&:to_i).join(',')})").map(&:to_i)
        existing = owned[fk.from_table] || []
        fresh = ids - existing
        next if fresh.empty?

        owned[fk.from_table] = existing + fresh
        changed = true
      end
      break unless changed
    end
    connection.disable_referential_integrity do
      owned.each { |table, ids| connection.execute("DELETE FROM #{connection.quote_table_name(table)} WHERE id IN (#{ids.map(&:to_i).join(',')})") }
    end
  end
end
