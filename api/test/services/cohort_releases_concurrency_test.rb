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
              operation_version: CoachOperations::CohortReleaseSeal::VERSION,
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
            operation_version: CoachOperations::CohortReleaseSeal::VERSION,
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

  test "persona publication cannot advance an assignment while stale release evidence is sealing" do
    owner, cohort, input = governed_operation_components
    persona = cohort.cohort_persona_assignment.coach_persona
    next_config = persona.draft_config.deep_dup
    next_config["identity"]["assistant_name"] = "Concurrent Mia #{SecureRandom.hex(3)}"
    Mia::PersonaDraftUpdater.new(persona: persona, actor: owner, workspace: persona.coach_workspace).call!(
      expected_draft_revision: persona.draft_revision,
      description: persona.description,
      draft_config: next_config
    )
    persona.reload
    publisher = Mia::PersonaPublisher.new(persona: persona, actor: owner)
    preview = publisher.preview!(expected_draft_revision: persona.draft_revision)
    evidence = persona_release_evidence(persona, actor: owner)
    publish_input = {
      expected_preview_digest: preview.fetch(:digest),
      expected_draft_revision: persona.draft_revision,
      expected_current_version_id: persona.current_published_version_id,
      **evidence
    }
    persona_locked = Queue.new
    allow_publish = Queue.new
    published = Queue.new
    publisher_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        CoachPersona.transaction do
          locked_persona = CoachPersona.lock.find(persona.id)
          persona_locked << true
          allow_publish.pop
          version = Mia::PersonaPublisher.new(persona: locked_persona, actor: User.find(owner.id)).publish!(**publish_input)
          published << version.id
        end
      rescue StandardError => error
        published << error
      end
    end
    Timeout.timeout(5) { persona_locked.pop }

    assert_raises(ActiveRecord::LockWaitTimeout) do
      Cohort.transaction do
        Cohort.connection.execute("SET LOCAL lock_timeout = '250ms'")
        CoachOperations::Runner.new(cohort: Cohort.find(cohort.id), actor: User.find(owner.id)).call!(
          operation_key: "cohort.release.seal",
          operation_version: CoachOperations::CohortReleaseSeal::VERSION,
          input: input,
          request_key: "persona-publish-lock-race"
        )
      end
    end
    assert_empty cohort.cohort_releases

    allow_publish << true
    publisher_thread.join(15)
    published_result = Timeout.timeout(5) { published.pop }
    assert_not publisher_thread.alive?
    assert_kind_of Integer, published_result, published_result.respond_to?(:full_message) ? published_result.full_message : nil
    assert_equal published_result, cohort.cohort_persona_assignment.reload.coach_persona_version_id

    assert_raises(CohortReleases::Sealer::Stale) do
      CoachOperations::Runner.new(cohort: Cohort.find(cohort.id), actor: User.find(owner.id)).call!(
        operation_key: "cohort.release.seal",
        operation_version: CoachOperations::CohortReleaseSeal::VERSION,
        input: input,
        request_key: "persona-publish-stale-evidence"
      )
    end
    assert_empty cohort.cohort_releases
  ensure
    allow_publish << true if defined?(allow_publish) && allow_publish
    publisher_thread&.join(15)
    cleanup_governed_operation_records(owner, cohort)
  end

  test "brand publication cannot advance while stale release evidence is sealing" do
    owner, cohort, input = governed_operation_components
    configuration = cohort.coach_workspace.workspace_brand_configuration
    next_config = configuration.draft_config.deep_dup
    next_config["product_name"] = "Concurrent Brand #{SecureRandom.hex(3)}"
    next_config["short_name"] = "Concurrent Brand"
    configuration.update!(draft_config: next_config, last_edited_by_user: owner)
    publisher = Branding::Publisher.new(configuration: configuration, actor: owner)
    preview = publisher.preview!(expected_draft_revision: configuration.reload.draft_revision)
    publish_input = {
      expected_preview_digest: preview,
      expected_draft_revision: configuration.draft_revision,
      expected_current_version_id: configuration.current_published_version_id,
      idempotency_key: "brand-publish-race-#{SecureRandom.hex(4)}"
    }
    brand_locked = Queue.new
    allow_publish = Queue.new
    published = Queue.new
    publisher_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        WorkspaceBrandConfiguration.transaction do
          locked_configuration = WorkspaceBrandConfiguration.lock.find(configuration.id)
          brand_locked << true
          allow_publish.pop
          version = Branding::Publisher.new(configuration: locked_configuration, actor: User.find(owner.id)).publish!(**publish_input)
          published << version.id
        end
      rescue StandardError => error
        published << error
      end
    end
    Timeout.timeout(5) { brand_locked.pop }

    assert_raises(ActiveRecord::LockWaitTimeout) do
      Cohort.transaction do
        Cohort.connection.execute("SET LOCAL lock_timeout = '250ms'")
        CoachOperations::Runner.new(cohort: Cohort.find(cohort.id), actor: User.find(owner.id)).call!(
          operation_key: CoachOperations::CohortReleaseSeal::KEY,
          operation_version: CoachOperations::CohortReleaseSeal::VERSION,
          input: input,
          request_key: "brand-publish-lock-race"
        )
      end
    end
    assert_empty cohort.cohort_releases

    allow_publish << true
    publisher_thread.join(15)
    published_result = Timeout.timeout(5) { published.pop }
    assert_not publisher_thread.alive?
    assert_kind_of Integer, published_result, published_result.respond_to?(:full_message) ? published_result.full_message : nil
    assert_equal published_result, configuration.reload.current_published_version_id

    assert_raises(CohortReleases::Sealer::Stale) do
      CoachOperations::Runner.new(cohort: Cohort.find(cohort.id), actor: User.find(owner.id)).call!(
        operation_key: CoachOperations::CohortReleaseSeal::KEY,
        operation_version: CoachOperations::CohortReleaseSeal::VERSION,
        input: input,
        request_key: "brand-publish-stale-evidence"
      )
    end
    assert_empty cohort.cohort_releases
  ensure
    allow_publish << true if defined?(allow_publish) && allow_publish
    publisher_thread&.join(15)
    cleanup_governed_operation_records(owner, cohort)
  end

  test "historical persona archival cannot race a governed restore" do
    owner, cohort, first_input = governed_operation_components
    first_persona = cohort.cohort_persona_assignment.coach_persona
    first_release = CoachOperations::Runner.new(cohort: cohort, actor: owner).call!(
      operation_key: "cohort.release.seal",
      operation_version: CoachOperations::CohortReleaseSeal::VERSION,
      input: first_input,
      request_key: "restore-archive-source"
    ).release

    second_persona_name = "Restore race persona #{SecureRandom.hex(4)}"
    second_persona = create_persona(
      creator: owner,
      name: second_persona_name,
      config: persona_configuration(assistant_name: second_persona_name),
      workspace: cohort.coach_workspace
    )
    second_persona_version = publish_persona(second_persona, actor: owner)
    CohortPersonaAssignment.transaction do
      locked_cohort = Cohort.lock.find(cohort.id)
      locked_persona = CoachPersona.lock.find(second_persona.id)
      locked_cohort.cohort_persona_assignment.update!(
        coach_persona: locked_persona,
        coach_persona_version: second_persona_version,
        assigned_by_user: owner
      )
    end
    cohort.reload
    current_candidate = CohortReleases::CandidateBuilder.new(cohort: cohort, strict: true).call
    second_input = {
      expected_assignment_id: cohort.cohort_persona_assignment.id,
      expected_bundle_digest: current_candidate.bundle_digest,
      expected_experience_version_id: current_candidate.experience_version.id,
      expected_latest_release_id: first_release.id,
      expected_persona_version_id: second_persona_version.id,
      expected_brand_version_id: current_candidate.brand_version&.id,
      expected_tool_registry_digest: CohortReleases::Contract.digest(current_candidate.tool_registry_snapshot),
      expected_tool_registry_version: CohortReleases::Contract::TOOL_REGISTRY_VERSION
    }
    second_release = CoachOperations::Runner.new(cohort: cohort, actor: owner).call!(
      operation_key: "cohort.release.seal",
      operation_version: CoachOperations::CohortReleaseSeal::VERSION,
      input: second_input,
      request_key: "restore-archive-current"
    ).release
    restore_input = {
      expected_latest_release_id: second_release.id,
      source_bundle_digest: first_release.bundle_digest,
      source_experience_version_id: first_release.cohort_experience_version_id,
      source_persona_version_id: first_release.coach_persona_version_id,
      source_brand_version_id: first_release.workspace_brand_version_id,
      source_release_id: first_release.id
    }
    persona_locked = Queue.new
    allow_archive = Queue.new
    archived = Queue.new
    archive_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        CoachPersona.transaction do
          locked_persona = CoachPersona.lock.find(first_persona.id)
          persona_locked << true
          allow_archive.pop
          locked_persona.archive!
          archived << true
        end
      rescue StandardError => error
        archived << error
      end
    end
    Timeout.timeout(5) { persona_locked.pop }

    assert_raises(ActiveRecord::LockWaitTimeout) do
      Cohort.transaction do
        Cohort.connection.execute("SET LOCAL lock_timeout = '250ms'")
        CoachOperations::Runner.new(cohort: Cohort.find(cohort.id), actor: User.find(owner.id)).call!(
          operation_key: "cohort.release.restore",
          operation_version: CoachOperations::CohortReleaseSeal::VERSION,
          input: restore_input,
          request_key: "restore-archive-lock-race"
        )
      end
    end
    assert_equal 2, cohort.cohort_releases.count

    allow_archive << true
    archive_thread.join(15)
    archived_result = Timeout.timeout(5) { archived.pop }
    assert_not archive_thread.alive?
    assert_equal true, archived_result, archived_result.respond_to?(:full_message) ? archived_result.full_message : nil
    assert first_persona.reload.archived?

    assert_raises(CohortReleases::Sealer::Incomplete) do
      CoachOperations::Runner.new(cohort: Cohort.find(cohort.id), actor: User.find(owner.id)).call!(
        operation_key: "cohort.release.restore",
        operation_version: CoachOperations::CohortReleaseSeal::VERSION,
        input: restore_input,
        request_key: "restore-archive-stale-evidence"
      )
    end
    assert_equal 2, cohort.cohort_releases.count
  ensure
    allow_archive << true if defined?(allow_archive) && allow_archive
    archive_thread&.join(15)
    cleanup_governed_operation_records(owner, cohort, extra_personas: [ first_persona ])
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
    delete_workspace_brand_records(workspace&.id)
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
    delete_workspace_brand_records(workspace&.id)
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
      expected_brand_version_id: candidate.brand_version&.id,
      expected_tool_registry_digest: CohortReleases::Contract.digest(candidate.tool_registry_snapshot),
      expected_tool_registry_version: CohortReleases::Contract::TOOL_REGISTRY_VERSION
    }
    [ owner, cohort, input ]
  end

  def cleanup_governed_operation_records(owner, cohort, extra_personas: [])
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

    ([ persona ] + extra_personas).compact.uniq(&:id).each { |item| cleanup_persona_records(item) }
    workspace = CoachWorkspace.find_by(id: cohort.coach_workspace_id)
    CoachProfile.where(coach_workspace_id: workspace&.id).delete_all
    CoachWorkspaceMembership.where(coach_workspace_id: workspace&.id).delete_all
    delete_workspace_brand_records(workspace&.id)
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
