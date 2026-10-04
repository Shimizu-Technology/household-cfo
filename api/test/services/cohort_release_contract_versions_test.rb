# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class CohortReleaseContractVersionsTest < ActiveSupport::TestCase
  include PersonaTestHelper

  teardown { CohortReleases::RuntimeIntegrityCache.clear! }

  test "historical release remains usable and unchanged after an unrelated operation is registered" do
    release = legacy_release
    original = release.attributes.deep_dup
    operations = HouseholdFinance::Operations::Registry.operations.merge("savings.example.create" => handler("savings.example.create", 1))

    with_operations(operations) do
      report = release.integrity_report
      assert report.fetch(:valid), report.inspect
      assert report.fetch(:runtime_compatible), report.inspect
      assert CohortReleases::RuntimeIntegrityCache.valid_runtime?(release)
      assert_equal original, release.reload.attributes
      assert_equal 1, CohortReleases::CandidateBuilder.new(cohort: release.cohort, strict: false).call.tool_registry_snapshot.fetch("schema_version")
    end
  end

  test "positive cache and supplied snapshot cannot hide a missing or incompatible live handler" do
    release = legacy_release
    assert CohortReleases::RuntimeIntegrityCache.valid_runtime?(release)
    original = HouseholdFinance::Operations::Registry.operations
    key = original.keys.first
    [ original.except(key), original.merge(key => handler(key, 2)) ].each do |operations|
      with_operations(operations) do
        refute release.integrity_report.fetch(:runtime_compatible)
        refute CohortReleases::RuntimeIntegrityCache.valid_runtime?(release)
        refute CohortReleases::Integrity.new(release,
          current_tool_registry_snapshot: CohortReleases::Contract.tool_registry_snapshot).call.fetch(:runtime_compatible)
        candidate = CohortReleases::CandidateBuilder.new(cohort: release.cohort, strict: false).call
        assert candidate.blockers.any? { |message| message.include?("tool contract") }
        studio = CohortReleases::StudioSerializer.new(cohort: release.cohort, actor: release.cohort.created_by_user).call
        controls = studio.dig(:readiness, :checks).find { |entry| entry.fetch(:id) == "system_controls" }
        refute controls.fetch(:ready)
      end
      assert CohortReleases::RuntimeIntegrityCache.valid_runtime?(release)
    end
  end

  test "a handler registered under another operation key fails closed" do
    release = legacy_release
    assert CohortReleases::RuntimeIntegrityCache.valid_runtime?(release)
    operations = HouseholdFinance::Operations::Registry.operations
    key = operations.keys.first
    with_operations(operations.merge(key => handler("incorrect.key", 1))) do
      refute release.integrity_report.fetch(:runtime_compatible)
      refute CohortReleases::RuntimeIntegrityCache.valid_runtime?(release)
    end
  end

  test "positive cache cannot conceal a changed required module definition" do
    release = legacy_release
    assert CohortReleases::RuntimeIntegrityCache.valid_runtime?(release)
    registry = CohortExperience::ModuleRegistry
    original = registry::MODULES
    changed = original.deep_dup
    changed.first[:core] = false
    registry.send(:remove_const, :MODULES)
    registry.const_set(:MODULES, changed.freeze)

    refute release.integrity_report.fetch(:runtime_compatible)
    refute CohortReleases::RuntimeIntegrityCache.valid_runtime?(release)
  ensure
    if original
      registry.send(:remove_const, :MODULES)
      registry.const_set(:MODULES, original)
    end
  end

  test "an additive core module does not enter an older sealed participant experience" do
    release = legacy_release
    registry = CohortExperience::ModuleRegistry
    original = registry::MODULES
    registry.send(:remove_const, :MODULES)
    registry.const_set(:MODULES, (original + [ { id: "future", label: "Future tool", core: true } ]).freeze)

    assert release.integrity_report.fetch(:runtime_compatible)
    capabilities = CohortExperience::EffectiveCapabilitiesResolver.for_release(release: release, cohort_membership: nil)
    ids = capabilities.fetch(:modules).map { |entry| entry.fetch(:id) }
    assert_equal release.tool_registry_snapshot.fetch("modules").map { |entry| entry.fetch("id") }, ids
    refute_includes ids, "future"
  ensure
    if original
      registry.send(:remove_const, :MODULES)
      registry.const_set(:MODULES, original)
    end
  end

  test "rehashing an arbitrary subset does not authorize it and cannot reuse a positive cache" do
    release = legacy_release
    assert CohortReleases::RuntimeIntegrityCache.valid_runtime?(release)
    release.tool_registry_snapshot = release.tool_registry_snapshot.deep_dup
    release.tool_registry_snapshot.fetch("operations").pop
    refute CohortReleases::RuntimeIntegrityCache.valid_runtime?(release)
    rebuild_bundle!(release)
    report = release.integrity_report
    assert report.fetch(:valid), report.inspect
    refute report.fetch(:runtime_compatible)
    refute CohortReleases::RuntimeIntegrityCache.valid_runtime?(release)
  end

  test "legacy and savings releases can roll forward and back without rewriting sealed evidence" do
    owner, cohort, participant = governed_cohort
    legacy = seal(cohort, owner, "legacy-tools")
    original = legacy.attributes.deep_dup
    launcher = CohortReleases::InitialLauncher.new(cohort: cohort, actor: owner)
    launcher.call!(release_id: legacy.id, preview_digest: launcher.preview.fetch(:preview_digest), request_key: "legacy-launch")
    assert_equal 1, runtime(participant).capabilities.fetch(:schema_version)

    publish_experience(cohort, owner, CohortExperience::Schema::SAVINGS_CONFIG)
    savings = seal(cohort, owner, "savings-tools")
    assert_equal 2, savings.tool_registry_version
    assert_equal 2, savings.bundle.dig("tool_registry", "version")
    assert savings.integrity_report.fetch(:runtime_compatible)
    assert legacy.integrity_report.fetch(:runtime_compatible)
    assert_equal original, legacy.reload.attributes
    assert_equal legacy.id, runtime(participant).release_id

    rollout = CoachOperations::Runner.new(cohort: cohort, actor: owner).call!(
      operation_key: "cohort.rollout.plan", operation_version: 2,
      input: {
        target_release_id: savings.id, expected_latest_release_id: savings.id,
        expected_roster_digest: CohortRollouts::Contract.roster_digest(cohort),
        waves: [ { name: "Synthetic pilot", user_ids: [ participant.id ] } ]
      }, request_key: "savings-wave-plan"
    ).rollout
    advance_input = transition_input(rollout).merge(readiness_digest: CohortRollouts::Contract.readiness_digest_for_advance(rollout))
    run_transition(owner, rollout, "cohort.rollout.advance", advance_input, "savings-wave")
    assert_equal savings.id, runtime(participant).release_id
    assert_equal "savings_challenge", runtime(participant).capabilities.fetch(:experience_mode)

    run_transition(owner, rollout, "cohort.rollout.rollback",
      transition_input(rollout).merge(rollback_release_id: legacy.id), "savings-rollback")
    assert_equal legacy.id, runtime(participant).release_id
    assert_equal 1, runtime(participant).capabilities.fetch(:schema_version)
    assert_equal original, legacy.reload.attributes

    # A restore creates another governed record carrying the source's contract,
    # even though the currently published experience selects contract two.
    restored = CohortReleases::Sealer.new(cohort: cohort, actor: owner).call!(
      request_key: "legacy-contract-restore", event_type: "restore", source_release: legacy,
      expected_bundle_digest: CohortReleases::RestoreCandidateBuilder.new(cohort: cohort, source_release: legacy).call.bundle_digest
    )
    assert_equal 1, restored.tool_registry_version
    assert_equal 1, restored.bundle.dig("tool_registry", "version")
    assert_equal legacy.tool_registry_snapshot, restored.tool_registry_snapshot
    assert restored.integrity_report.fetch(:runtime_compatible)
    assert_equal original, legacy.reload.attributes
  end

  private

  def legacy_release
    owner = persona_user
    cohort = Cohort.create!(name: "Legacy catalog #{SecureRandom.hex(4)}", created_by_user: owner)
    CohortReleases::LegacyReconciler.new(scope: Cohort.where(id: cohort.id)).call
    cohort.cohort_releases.sole
  end

  def handler(key, version)
    Class.new.tap { |klass| klass.const_set(:KEY, key); klass.const_set(:VERSION, version) }
  end

  def with_operations(operations)
    registry = HouseholdFinance::Operations::Registry
    original = registry.method(:operations)
    registry.define_singleton_method(:operations) { operations }
    yield
  ensure
    registry&.define_singleton_method(:operations, original) if original
  end

  def rebuild_bundle!(release)
    contract = CohortReleases::Contract
    release.tool_registry_digest = contract.digest(release.tool_registry_snapshot)
    release.bundle = contract.bundle(schema: release.manifest_schema, cohort: release.cohort,
      persona_snapshot: release.persona_snapshot, experience_snapshot: release.experience_snapshot,
      brand_snapshot: release.brand_snapshot, tool_registry_snapshot: release.tool_registry_snapshot)
    release.bundle_digest = contract.digest(release.bundle)
    release.manifest = contract.manifest(schema: release.manifest_schema, release_number: release.release_number,
      publication_source: release.publication_source, event_type: release.event_type,
      released_by_user_id: release.released_by_user_id, actor_role_snapshot: release.actor_role_snapshot,
      source_release_id: release.source_release_id, request_key: release.request_key,
      request_fingerprint: release.request_fingerprint, released_at: release.released_at, bundle_digest: release.bundle_digest)
    release.manifest_digest = contract.digest(release.manifest)
  end

  def governed_cohort
    owner = persona_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    cohort = Cohort.create!(name: "Versioned synthetic pilot", status: "active", created_by_user: owner, coach_workspace: workspace)
    persona = create_persona(creator: owner, workspace: workspace)
    version = publish_persona(persona, actor: owner)
    CohortPersonaAssignment.create!(cohort: cohort, coach_workspace: workspace, coach_persona: persona,
      coach_persona_version: version, assigned_by_user: owner)
    publish_experience(cohort, owner, CohortExperience::Schema::DEFAULT_CONFIG)
    participant = persona_user(role: "participant")
    cohort.cohort_memberships.create!(user: participant, role: "participant")
    [ owner, cohort, participant ]
  end

  def publish_experience(cohort, owner, config)
    configuration = cohort.cohort_experience_configuration
    configuration.update!(draft_config: config, last_edited_by_user: owner)
    publisher = CohortExperience::Publisher.new(configuration: configuration, actor: owner)
    digest = publisher.preview!(expected_draft_revision: configuration.draft_revision)
    publisher.publish!(expected_preview_digest: digest, expected_draft_revision: configuration.draft_revision,
      expected_current_version_id: configuration.current_published_version_id)
  end

  def seal(cohort, owner, key)
    candidate = CohortReleases::CandidateBuilder.new(cohort: cohort, strict: true).call
    CoachOperations::Runner.new(cohort: cohort, actor: owner).call!(
      operation_key: "cohort.release.seal", operation_version: 2,
      input: {
        expected_assignment_id: candidate.assignment.id, expected_bundle_digest: candidate.bundle_digest,
        expected_experience_version_id: candidate.experience_version.id,
        expected_latest_release_id: cohort.cohort_releases.order(release_number: :desc).pick(:id),
        expected_persona_version_id: candidate.persona_version.id, expected_brand_version_id: candidate.brand_version&.id,
        expected_tool_registry_digest: CohortReleases::Contract.digest(candidate.tool_registry_snapshot),
        expected_tool_registry_version: candidate.tool_registry_snapshot.fetch("schema_version")
      }, request_key: key
    ).release
  end

  def runtime(user)
    Mia::ParticipantRuntimeResolver.new(user: user).call
  end

  def transition_input(rollout)
    rollout.reload
    { rollout_id: rollout.id, expected_status: rollout.status, expected_current_wave_position: rollout.current_wave_position,
      expected_latest_transition_id: rollout.transitions.reorder(id: :desc).pick(:id) }
  end

  def run_transition(owner, rollout, operation, input, key)
    CoachOperations::Runner.new(cohort: rollout.cohort, actor: owner).call!(
      operation_key: operation, operation_version: 2, input: input, request_key: key
    )
  end
end
