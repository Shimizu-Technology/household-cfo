# frozen_string_literal: true

require "test_helper"
require "timeout"
require_relative "../support/persona_test_helper"

class CohortReleasesConcurrencyTest < ActiveSupport::TestCase
  include PersonaTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  test "different request keys racing for one reviewed user bundle produce one release and one no-op" do
    owner, cohort, input = governed_operation_components
    ready = Queue.new
    start = Queue.new
    outcomes = Queue.new
    threads = %w[racing-key-one racing-key-two].map do |request_key|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          outcome = begin
            CoachOperations::Runner.new(cohort: Cohort.find(cohort.id), actor: User.find(owner.id)).call!(
              operation_key: "cohort.release.seal",
              operation_version: 1,
              input: input,
              request_key: request_key
            )
          rescue StandardError => error
            error
          end
          outcomes << outcome
        end
      end
    end
    Timeout.timeout(5) { 2.times { ready.pop } }
    2.times { start << true }
    threads.each { |thread| thread.join(15) }
    results = 2.times.map { Timeout.timeout(5) { outcomes.pop } }

    assert threads.none?(&:alive?), "concurrent coach operations did not finish"
    assert_equal 1, results.count { |result| result.is_a?(CoachOperations::Runner::Result) }
    assert_equal 1, results.count { |result| result.is_a?(CohortReleases::Sealer::AlreadyRecorded) }
    assert_equal 1, cohort.cohort_releases.count
    assert_equal 1, cohort.coach_operation_executions.count
  ensure
    2.times { start << true } if defined?(start)
    threads&.each { |thread| thread.join(1) }
    cleanup_governed_operation_records(owner, cohort)
  end

  test "persona assignment and release sealing share cohort then persona lock order without deadlock" do
    owner, cohort, input = governed_operation_components
    persona = cohort.cohort_persona_assignment.coach_persona
    ready = Queue.new
    start = Queue.new
    outcomes = Queue.new
    assignment_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ready << true
        start.pop
        outcome = begin
          CohortPersonaAssignment.transaction do
            locked_cohort = Cohort.lock.find(cohort.id)
            locked_persona = CoachPersona.lock.find(persona.id)
            current = locked_cohort.cohort_persona_assignment
            current.update!(
              coach_persona: locked_persona,
              coach_persona_version: locked_persona.current_published_version,
              assigned_by_user: owner
            )
          end
          :assigned
        rescue StandardError => error
          error
        end
        outcomes << outcome
      end
    end
    seal_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ready << true
        start.pop
        outcome = begin
          CoachOperations::Runner.new(cohort: Cohort.find(cohort.id), actor: User.find(owner.id)).call!(
            operation_key: "cohort.release.seal",
            operation_version: 1,
            input: input,
            request_key: "assignment-seal-race"
          )
        rescue StandardError => error
          error
        end
        outcomes << outcome
      end
    end
    Timeout.timeout(5) { 2.times { ready.pop } }
    2.times { start << true }
    [ assignment_thread, seal_thread ].each { |thread| thread.join(15) }
    results = 2.times.map { Timeout.timeout(5) { outcomes.pop } }

    assert_not assignment_thread.alive?
    assert_not seal_thread.alive?
    assert_includes results, :assigned
    assert results.any? { |result| result.is_a?(CoachOperations::Runner::Result) }
    refute results.any? { |result| result.is_a?(ActiveRecord::Deadlocked) }
  ensure
    2.times { start << true } if defined?(start)
    assignment_thread&.join(1)
    seal_thread&.join(1)
    cleanup_governed_operation_records(owner, cohort)
  end

  test "concurrent retries seal one release and conflicting requests receive monotonic numbers" do
    suffix = SecureRandom.hex(6)
    owner = User.create!(
      clerk_id: "release_concurrency_#{suffix}",
      email: "release-concurrency-#{suffix}@example.com",
      role: "coach",
      invitation_status: "accepted"
    )
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    cohort = Cohort.create!(
      name: "Release concurrency #{suffix}",
      status: "active",
      created_by_user: owner,
      coach_workspace: workspace
    )

    same_request = concurrently(4.times.map { "same-request" }) do |request_key|
      CohortReleases::Sealer.new(cohort: Cohort.find(cohort.id), actor: nil, publication_source: "system").call!(
        request_key: request_key,
        event_type: "reconciliation"
      )
    end
    assert_equal 1, same_request.map(&:id).uniq.length
    assert_equal 1, cohort.cohort_releases.count

    separate_requests = concurrently(%w[second-request third-request]) do |request_key|
      CohortReleases::Sealer.new(cohort: Cohort.find(cohort.id), actor: nil, publication_source: "system").call!(
        request_key: request_key,
        event_type: "reconciliation"
      )
    end
    assert_equal 2, separate_requests.map(&:id).uniq.length
    assert_equal [ 1, 2, 3 ], cohort.cohort_releases.order(:release_number).pluck(:release_number)
    assert cohort.cohort_releases.all?(&:integrity_valid?)
  ensure
    if CohortRelease.table_exists?
      begin
        CohortRelease.connection.execute("ALTER TABLE cohort_releases DISABLE TRIGGER cohort_releases_immutable")
        CohortRelease.where(cohort_id: cohort&.id).delete_all
      ensure
        CohortRelease.connection.execute("ALTER TABLE cohort_releases ENABLE TRIGGER cohort_releases_immutable")
      end
    end
    CohortExperienceConfiguration.where(cohort_id: cohort&.id).delete_all
    Cohort.where(id: cohort&.id).delete_all
    CoachProfile.where(coach_workspace_id: workspace&.id).delete_all
    CoachWorkspaceMembership.where(coach_workspace_id: workspace&.id).delete_all
    CoachWorkspace.where(id: workspace&.id).delete_all
    User.where(id: owner&.id).delete_all
  end

  test "a membership downgrade that wins the lock race revokes release authority" do
    suffix = SecureRandom.hex(6)
    owner = create_staff("release-owner-#{suffix}")
    reviewer = create_staff("release-reviewer-#{suffix}")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    membership = workspace.coach_workspace_memberships.create!(user: reviewer, role: "reviewer")
    cohort = Cohort.create!(name: "Release authority #{suffix}", status: "active",
      created_by_user: owner, coach_workspace: workspace)
    candidate = CohortReleases::CandidateBuilder.new(cohort: cohort, strict: true).call
    membership_locked = Queue.new
    allow_downgrade = Queue.new
    sealer_started = Queue.new
    sealer_result = Queue.new

    downgrade_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        CoachWorkspaceMembership.transaction do
          locked = CoachWorkspaceMembership.lock.find(membership.id)
          membership_locked << true
          allow_downgrade.pop
          locked.update!(role: "viewer")
        end
      end
    end
    Timeout.timeout(5) { membership_locked.pop }
    sealer_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        sealer_started << true
        result = begin
          CohortReleases::Sealer.new(cohort: Cohort.find(cohort.id), actor: User.find(reviewer.id)).call!(
            request_key: "revoked-reviewer",
            expected_bundle_digest: candidate.bundle_digest
          )
        rescue StandardError => error
          error
        end
        sealer_result << result
      end
    end
    Timeout.timeout(5) { sealer_started.pop }
    allow_downgrade << true
    downgrade_thread.join(10)
    sealer_thread.join(10)

    assert_not downgrade_thread.alive?
    assert_not sealer_thread.alive?
    assert_instance_of CohortReleases::Sealer::NotAuthorized, Timeout.timeout(5) { sealer_result.pop }
    assert_empty cohort.cohort_releases
    assert_equal "viewer", membership.reload.role
  ensure
    allow_downgrade << true if defined?(allow_downgrade)
    downgrade_thread&.join(1)
    sealer_thread&.join(1)
    CohortRelease.connection.execute("ALTER TABLE cohort_releases DISABLE TRIGGER cohort_releases_immutable") if CohortRelease.table_exists?
    CohortRelease.where(cohort_id: cohort&.id).delete_all if CohortRelease.table_exists?
    CohortRelease.connection.execute("ALTER TABLE cohort_releases ENABLE TRIGGER cohort_releases_immutable") if CohortRelease.table_exists?
    CohortExperienceConfiguration.where(cohort_id: cohort&.id).delete_all
    Cohort.where(id: cohort&.id).delete_all
    CoachProfile.where(coach_workspace_id: workspace&.id).delete_all
    CoachWorkspaceMembership.where(coach_workspace_id: workspace&.id).delete_all
    CoachWorkspace.where(id: workspace&.id).delete_all
    User.where(id: [ owner&.id, reviewer&.id ].compact).delete_all
  end

  private

  def concurrently(values)
    ready = Queue.new
    release = Queue.new
    results = Queue.new
    errors = Queue.new
    threads = values.map do |value|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          results << yield(value)
        rescue StandardError => error
          errors << error
        end
      end
    end
    Timeout.timeout(5) { values.length.times { ready.pop } }
    values.length.times { release << true }
    threads.each { |thread| thread.join(10) }

    assert threads.none?(&:alive?), "concurrent cohort release sealing did not finish"
    assert errors.empty?, errors.size.times.map { errors.pop.full_message }.join("\n")
    values.length.times.map { results.pop }
  ensure
    values.length.times { release << true } if defined?(release)
    threads&.each { |thread| thread.join(1) }
  end

  def create_staff(label)
    User.create!(
      clerk_id: "clerk_#{label}",
      email: "#{label}@example.com",
      role: "coach",
      invitation_status: "accepted"
    )
  end

  def governed_operation_components
    owner = persona_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    cohort = Cohort.create!(
      name: "Operation concurrency #{SecureRandom.hex(6)}",
      status: "active",
      created_by_user: owner,
      coach_workspace: workspace
    )
    persona = create_persona(
      creator: owner,
      name: "Concurrency persona #{SecureRandom.hex(6)}",
      workspace: workspace
    )
    version = publish_persona(persona, actor: owner)
    assignment = CohortPersonaAssignment.create!(
      cohort: cohort,
      coach_workspace: workspace,
      coach_persona: persona,
      coach_persona_version: version,
      assigned_by_user: owner
    )
    configuration = cohort.cohort_experience_configuration
    publisher = CohortExperience::Publisher.new(configuration: configuration, actor: owner)
    preview = publisher.preview!(expected_draft_revision: configuration.draft_revision)
    experience = publisher.publish!(
      expected_preview_digest: preview,
      expected_draft_revision: configuration.reload.draft_revision,
      expected_current_version_id: nil
    )
    candidate = CohortReleases::CandidateBuilder.new(cohort: cohort, strict: true).call
    input = {
      expected_assignment_id: assignment.id,
      expected_bundle_digest: candidate.bundle_digest,
      expected_experience_version_id: experience.id,
      expected_latest_release_id: nil,
      expected_persona_version_id: version.id,
      expected_tool_registry_digest: CohortReleases::Contract.digest(candidate.tool_registry_snapshot),
      expected_tool_registry_version: CohortReleases::Contract::TOOL_REGISTRY_VERSION
    }
    [ owner, cohort, input ]
  end

  def cleanup_governed_operation_records(owner, cohort)
    return unless owner && cohort

    assignment = CohortPersonaAssignment.find_by(cohort_id: cohort.id)
    persona = assignment&.coach_persona
    configuration = CohortExperienceConfiguration.find_by(cohort_id: cohort.id)
    CoachOperationExecution.connection.execute(
      "ALTER TABLE coach_operation_executions DISABLE TRIGGER coach_operation_executions_immutable"
    )
    CohortRelease.connection.execute("ALTER TABLE cohort_releases DISABLE TRIGGER cohort_releases_immutable")
    CoachOperationExecution.where(cohort_id: cohort.id).delete_all
    CohortRelease.where(cohort_id: cohort.id).delete_all
    CohortRelease.connection.execute("ALTER TABLE cohort_releases ENABLE TRIGGER cohort_releases_immutable")
    CoachOperationExecution.connection.execute(
      "ALTER TABLE coach_operation_executions ENABLE TRIGGER coach_operation_executions_immutable"
    )

    CohortPersonaAssignment.where(cohort_id: cohort.id).delete_all
    if configuration
      configuration.update_columns(current_published_version_id: nil)
      CohortExperiencePublicationEvent.where(cohort_experience_configuration_id: configuration.id).delete_all
      CohortExperienceVersion.where(cohort_experience_configuration_id: configuration.id).delete_all
      configuration.delete
    end
    CohortMembership.where(cohort_id: cohort.id).delete_all
    cohort.delete

    cleanup_persona_records(persona) if persona
    workspace = CoachWorkspace.find_by(id: cohort.coach_workspace_id)
    CoachProfile.where(coach_workspace_id: workspace&.id).delete_all
    CoachWorkspaceMembership.where(coach_workspace_id: workspace&.id).delete_all
    workspace&.delete
    owner.delete
  ensure
    if CoachOperationExecution.table_exists?
      CoachOperationExecution.connection.execute(
        "ALTER TABLE coach_operation_executions ENABLE TRIGGER coach_operation_executions_immutable"
      )
    end
    if CohortRelease.table_exists?
      CohortRelease.connection.execute("ALTER TABLE cohort_releases ENABLE TRIGGER cohort_releases_immutable")
    end
  end

  def cleanup_persona_records(persona)
    candidate_ids = CoachPersonaReleaseCandidate.where(coach_persona_id: persona.id).pluck(:id)
    run_ids = CoachPersonaEvaluationRun.where(coach_persona_release_candidate_id: candidate_ids).pluck(:id)
    persona.update_columns(current_published_version_id: nil)
    CoachPersonaPublicationEvent.where(coach_persona_id: persona.id).delete_all
    CoachPersonaVersionContentPack.where(coach_persona_version_id: persona.version_ids).delete_all
    CoachPersonaVersionPhraseArtifact.where(coach_persona_version_id: persona.version_ids).delete_all
    CoachPersonaVersion.where(coach_persona_id: persona.id).delete_all
    CoachPersonaEvaluationApproval.where(coach_persona_evaluation_run_id: run_ids).delete_all
    CoachPersonaEvaluationResult.where(coach_persona_evaluation_run_id: run_ids).delete_all
    CoachPersonaEvaluationRun.where(id: run_ids).delete_all
    CoachPersonaBehavioralPreviewEvidence.where(coach_persona_release_candidate_id: candidate_ids).delete_all
    CoachPhraseAudienceAttestation.where(coach_persona_release_candidate_id: candidate_ids).delete_all
    CoachPersonaReleaseCandidate.where(id: candidate_ids).delete_all
    CoachPersonaEvaluationCase.where(coach_persona_id: persona.id).delete_all
    persona.delete
  end
end
