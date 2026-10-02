# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class CohortReleasesFoundationTest < ActiveSupport::TestCase
  include PersonaTestHelper
  include ActiveJob::TestHelper

  test "contract produces a stable sorted registry and canonical digest" do
    first = CohortReleases::Contract.tool_registry_snapshot
    second = CohortReleases::Contract.tool_registry_snapshot.deep_dup.reverse_merge("ignored" => nil).except("ignored")

    assert_equal first, second
    assert_equal CohortReleases::Contract.digest(first), CohortReleases::Contract.digest(second)
    assert_equal first.fetch("operations").map { |entry| entry.fetch("key") }.sort,
      first.fetch("operations").map { |entry| entry.fetch("key") }
    assert_equal CohortExperience::ModuleRegistry::MODULES.length, first.fetch("modules").length
    assert first.fetch("operations").all? { |entry| entry.fetch("version").positive? }
  end

  test "legacy reconciliation truthfully seals neutral persona and safe default tools without changing runtime" do
    owner = persona_user
    cohort = Cohort.create!(
      name: "Legacy release #{SecureRandom.hex(4)}",
      status: "active",
      created_by_user: owner
    )

    counts = CohortReleases::LegacyReconciler.new(scope: Cohort.where(id: cohort.id)).call
    release = cohort.cohort_releases.sole

    assert_equal 1, counts.fetch(:sealed)
    assert_equal "legacy_backfill", release.publication_source
    assert_equal "reconciliation", release.event_type
    assert_nil release.released_by_user
    assert_equal "neutral_builtin", release.persona_mode
    assert_equal "safe_default", release.experience_mode
    assert release.integrity_valid?, release.integrity_report.fetch(:errors).join("\n")
    assert_equal "in_sync", CohortReleases::ShadowParity.new(cohort).call.fetch(:state)
    assert_nil cohort.cohort_persona_assignment
    assert_nil cohort.cohort_experience_configuration.current_published_version

    repeated = CohortReleases::LegacyReconciler.new(scope: Cohort.where(id: cohort.id)).call
    assert_equal 1, repeated.fetch(:replayed)
    assert_equal 1, cohort.cohort_releases.count
  end

  test "governed persona and tools can be sealed idempotently as one immutable bundle" do
    owner, cohort, assignment, persona_version, experience_version = governed_release_components
    candidate = CohortReleases::CandidateBuilder.new(cohort: cohort, strict: true).call

    assert_empty candidate.blockers
    release = CohortReleases::Sealer.new(cohort: cohort, actor: owner).call!(
      request_key: "release-1",
      expected_bundle_digest: candidate.bundle_digest,
      expected_assignment_id: assignment.id,
      expected_persona_version_id: persona_version.id,
      expected_experience_version_id: experience_version.id
    )

    assert_equal 1, release.release_number
    assert_equal "published_version", release.persona_mode
    assert_equal "published_version", release.experience_mode
    assert_equal "owner", release.actor_role_snapshot
    assert_equal persona_version, release.coach_persona_version
    assert_equal experience_version, release.cohort_experience_version
    assert release.integrity_valid?, release.integrity_report.fetch(:errors).join("\n")
    assert release.integrity_report.fetch(:runtime_compatible)
    assert_equal release, CohortReleases::Sealer.new(cohort: cohort, actor: owner).call!(
      request_key: "release-1",
      expected_bundle_digest: candidate.bundle_digest,
      expected_assignment_id: assignment.id,
      expected_persona_version_id: persona_version.id,
      expected_experience_version_id: experience_version.id
    )
    assert_equal 1, cohort.cohort_releases.count

    assert_raises(CohortReleases::Sealer::RequestConflict) do
      CohortReleases::Sealer.new(cohort: cohort, actor: owner).call!(
        request_key: "release-1",
        expected_bundle_digest: "f" * 64
      )
    end
    [
      { expected_assignment_id: assignment.id + 1 },
      { expected_persona_version_id: persona_version.id + 1 },
      { expected_experience_version_id: experience_version.id + 1 }
    ].each do |changed_expectation|
      assert_raises(CohortReleases::Sealer::RequestConflict) do
        CohortReleases::Sealer.new(cohort: cohort, actor: owner).call!(
          request_key: "release-1",
          expected_bundle_digest: candidate.bundle_digest,
          expected_assignment_id: assignment.id,
          expected_persona_version_id: persona_version.id,
          expected_experience_version_id: experience_version.id,
          **changed_expectation
        )
      end
    end
    assert_raises(CohortReleases::Sealer::Stale) do
      CohortReleases::Sealer.new(cohort: cohort, actor: owner).call!(request_key: "release-1")
    end
  end

  test "strict sealing fails closed for fallback components and stale expectations" do
    owner = persona_user
    cohort = Cohort.create!(name: "Incomplete release #{SecureRandom.hex(4)}", created_by_user: owner)
    candidate = CohortReleases::CandidateBuilder.new(cohort: cohort, strict: true).call

    assert_equal 2, candidate.blockers.length
    error = assert_raises(CohortReleases::Sealer::Incomplete) do
      CohortReleases::Sealer.new(cohort: cohort, actor: owner).call!(
        request_key: "missing-components",
        expected_bundle_digest: candidate.bundle_digest
      )
    end
    assert_equal candidate.blockers, error.blockers
    assert_empty cohort.cohort_releases
  end

  test "sealed rows reject Active Record and raw SQL mutation while integrity still detects in-memory corruption" do
    owner = persona_user
    cohort = Cohort.create!(name: "Immutable release #{SecureRandom.hex(4)}", created_by_user: owner)
    release = CohortReleases::LegacyReconciler.new(scope: Cohort.where(id: cohort.id)).tap(&:call)
      .then { cohort.cohort_releases.sole }

    refute release.update(request_key: "changed")
    assert_includes release.errors[:base], "cohort releases are immutable"
    refute release.destroy
    assert_includes release.errors[:base], "cohort releases cannot be deleted"

    assert_raises(ActiveRecord::StatementInvalid) do
      CohortRelease.transaction(requires_new: true) do
        release.update_column(:bundle_digest, "0" * 64)
      end
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      CohortRelease.transaction(requires_new: true) do
        CohortRelease.connection.execute("DELETE FROM cohort_releases WHERE id = #{release.id}")
      end
    end
    assert release.reload.integrity_valid?
    release.bundle_digest = "0" * 64
    refute release.integrity_valid?
    assert_includes release.integrity_report.fetch(:errors), "Release bundle digest does not match"
  end

  test "self-consistent forged fallback and registry snapshots are rejected on create" do
    owner = persona_user
    cohort = Cohort.create!(name: "Forged release #{SecureRandom.hex(4)}", created_by_user: owner)
    CohortReleases::LegacyReconciler.new(scope: Cohort.where(id: cohort.id)).call
    release = cohort.cohort_releases.sole

    mutations = [
      ->(copy) { copy.persona_snapshot = copy.persona_snapshot.deep_merge("data" => { "name" => "Forged" }) },
      ->(copy) { copy.experience_snapshot = copy.experience_snapshot.deep_merge("config" => CohortExperience::Schema::LEGACY_CONFIG) },
      ->(copy) { copy.tool_registry_snapshot = copy.tool_registry_snapshot.deep_merge("schema_version" => 999) }
    ]
    mutations.each_with_index do |mutation, index|
      copy = release.dup
      copy.release_number = index + 2
      copy.request_key = "forged-#{index}"
      copy.request_fingerprint = Digest::SHA256.hexdigest("forged-#{index}")
      copy.released_at = Time.current
      mutation.call(copy)
      copy.persona_snapshot_digest = CohortReleases::Contract.digest(copy.persona_snapshot)
      copy.experience_snapshot_digest = CohortReleases::Contract.digest(copy.experience_snapshot)
      copy.tool_registry_digest = CohortReleases::Contract.digest(copy.tool_registry_snapshot)
      copy.bundle = CohortReleases::Contract.bundle(
        cohort: cohort,
        persona_snapshot: copy.persona_snapshot,
        experience_snapshot: copy.experience_snapshot,
        tool_registry_snapshot: copy.tool_registry_snapshot
      )
      copy.bundle_digest = CohortReleases::Contract.digest(copy.bundle)
      copy.manifest = CohortReleases::Contract.manifest(
        release_number: copy.release_number,
        publication_source: copy.publication_source,
        event_type: copy.event_type,
        released_by_user_id: nil,
        actor_role_snapshot: nil,
        source_release_id: nil,
        request_key: copy.request_key,
        request_fingerprint: copy.request_fingerprint,
        released_at: copy.released_at,
        bundle_digest: copy.bundle_digest
      )
      copy.manifest_digest = CohortReleases::Contract.digest(copy.manifest)

      refute copy.valid?
      assert_includes copy.errors[:base], "cohort release snapshots must match the current sealed runtime contract"
    end
  end

  test "database composite keys reject a release workspace from another tenant" do
    first_owner = persona_user
    second_owner = persona_user
    cohort = Cohort.create!(name: "Tenant release #{SecureRandom.hex(4)}", created_by_user: first_owner)
    other_workspace = CoachWorkspaces::Provisioner.ensure_for!(second_owner)
    CohortReleases::LegacyReconciler.new(scope: Cohort.where(id: cohort.id)).call
    release = cohort.cohort_releases.sole

    forged = release.attributes.except("id")
    forged["coach_workspace_id"] = other_workspace.id
    forged["release_number"] = 2
    forged["request_key"] = "cross-tenant"
    forged["request_fingerprint"] = "f" * 64
    assert_raises(ActiveRecord::InvalidForeignKey) do
      CohortRelease.transaction(requires_new: true) { CohortRelease.insert_all!([ forged ]) }
    end
    assert_equal cohort.coach_workspace_id, release.reload.coach_workspace_id
  end

  test "shadow parity detects staged persona or participant-tool drift without exposing private data" do
    owner, cohort, = governed_release_components
    candidate = CohortReleases::CandidateBuilder.new(cohort: cohort, strict: true).call
    CohortReleases::Sealer.new(cohort: cohort, actor: owner).call!(
      request_key: "parity-release",
      expected_bundle_digest: candidate.bundle_digest
    )
    assert_equal "in_sync", CohortReleases::ShadowParity.new(cohort).call.fetch(:state)

    configuration = cohort.cohort_experience_configuration
    configuration.update!(
      draft_config: CohortExperience::Schema::LEGACY_CONFIG,
      last_edited_by_user: owner
    )
    publisher = CohortExperience::Publisher.new(configuration: configuration, actor: owner)
    digest = publisher.preview!(expected_draft_revision: configuration.draft_revision)
    publisher.publish!(
      expected_preview_digest: digest,
      expected_draft_revision: configuration.reload.draft_revision,
      expected_current_version_id: configuration.current_published_version_id
    )

    payload = CohortReleases::ShadowParity.new(cohort).call
    assert_equal "drifted", payload.fetch(:state)
    assert_equal %i[cohort_id experience_mode persona_mode publication_source release_id release_number runtime_compatible state warning_count],
      payload.keys.sort
  end

  test "restore seals the selected historical bundle after staging has changed" do
    owner, cohort, = governed_release_components
    first_candidate = CohortReleases::CandidateBuilder.new(cohort: cohort, strict: true).call
    first = CohortReleases::Sealer.new(cohort: cohort, actor: owner).call!(
      request_key: "first-release",
      expected_bundle_digest: first_candidate.bundle_digest
    )

    configuration = cohort.cohort_experience_configuration
    configuration.update!(draft_config: CohortExperience::Schema::LEGACY_CONFIG, last_edited_by_user: owner)
    publisher = CohortExperience::Publisher.new(configuration: configuration, actor: owner)
    digest = publisher.preview!(expected_draft_revision: configuration.draft_revision)
    publisher.publish!(
      expected_preview_digest: digest,
      expected_draft_revision: configuration.reload.draft_revision,
      expected_current_version_id: configuration.current_published_version_id
    )
    refute_equal first.bundle_digest,
      CohortReleases::CandidateBuilder.new(cohort: cohort, strict: true).call.bundle_digest
    assert first.integrity_valid?, first.integrity_report.fetch(:errors).join("\n")

    restored = CohortReleases::Sealer.new(cohort: cohort, actor: owner).call!(
      request_key: "restore-first",
      expected_bundle_digest: first.bundle_digest,
      event_type: "restore",
      source_release: first
    )

    assert_equal 2, restored.release_number
    assert_equal "restore", restored.event_type
    assert_equal first, restored.source_release
    assert_equal first.bundle, restored.bundle
    assert_equal first.bundle_digest, restored.bundle_digest
    assert restored.integrity_valid?
    assert_equal "drifted", CohortReleases::ShadowParity.new(cohort).call.fetch(:state)
  end

  test "direct creation cannot seal an unassigned persona from the same workspace" do
    owner, cohort, = governed_release_components
    canonical = CohortReleases::CandidateBuilder.new(cohort: cohort, strict: true).call
    release = CohortReleases::Sealer.new(cohort: cohort, actor: owner).call!(
      request_key: "canonical-persona",
      expected_bundle_digest: canonical.bundle_digest
    )
    unassigned_persona = create_persona(
      creator: owner,
      name: "Unassigned release persona #{SecureRandom.hex(4)}",
      workspace: cohort.coach_workspace,
      config: persona_configuration(assistant_name: "Unassigned #{SecureRandom.hex(4)}")
    )
    unassigned_version = publish_persona(unassigned_persona, actor: owner)
    forged = duplicate_release(release, release_number: 2, request_key: "unassigned-persona")
    forged.coach_persona = unassigned_persona
    forged.coach_persona_version = unassigned_version
    forged.persona_snapshot = CohortReleases::Contract.persona_snapshot(version: unassigned_version)
    rebuild_release_bundle!(forged)
    rebuild_release_manifest!(forged)

    refute forged.valid?
    assert_includes forged.errors[:base], "cohort release must match the cohort's current canonical configuration"
    assert_empty forged.errors[:base].grep(/digest does not match|immutable version/)
  end

  test "direct creation cannot seal a stale experience version after publication advances" do
    owner, cohort, = governed_release_components
    candidate = CohortReleases::CandidateBuilder.new(cohort: cohort, strict: true).call
    release = CohortReleases::Sealer.new(cohort: cohort, actor: owner).call!(
      request_key: "experience-v1",
      expected_bundle_digest: candidate.bundle_digest
    )
    configuration = cohort.cohort_experience_configuration
    configuration.update!(draft_config: CohortExperience::Schema::LEGACY_CONFIG, last_edited_by_user: owner)
    publisher = CohortExperience::Publisher.new(configuration: configuration, actor: owner)
    preview = publisher.preview!(expected_draft_revision: configuration.draft_revision)
    publisher.publish!(
      expected_preview_digest: preview,
      expected_draft_revision: configuration.reload.draft_revision,
      expected_current_version_id: configuration.current_published_version_id
    )
    forged = duplicate_release(release, release_number: 2, request_key: "stale-experience")

    refute forged.valid?
    assert_includes forged.errors[:base], "cohort release must match the cohort's current canonical configuration"
    assert release.integrity_valid?, release.integrity_report.fetch(:errors).join("\n")
  end

  test "direct creation cannot forge the actor or recorded workspace role" do
    owner, cohort, = governed_release_components
    candidate = CohortReleases::CandidateBuilder.new(cohort: cohort, strict: true).call
    release = CohortReleases::Sealer.new(cohort: cohort, actor: owner).call!(
      request_key: "authorized-source",
      expected_bundle_digest: candidate.bundle_digest
    )
    participant = persona_user(role: "participant")
    viewer = persona_user
    CoachWorkspaceMembership.create!(coach_workspace: cohort.coach_workspace, user: viewer, role: "viewer")

    [
      [ participant, "owner", "participant-authority" ],
      [ viewer, "reviewer", "viewer-authority" ],
      [ owner, "reviewer", "false-role-snapshot" ]
    ].each_with_index do |(actor, claimed_role, request_key), index|
      forged = duplicate_release(release, release_number: index + 2, request_key: request_key)
      forged.released_by_user = actor
      forged.actor_role_snapshot = claimed_role
      rebuild_release_manifest!(forged)

      refute forged.valid?
      assert forged.errors[:released_by_user].any?
    end
  end

  test "published release snapshots never copy participant-scoped phrase data" do
    owner = persona_user
    participant = persona_user(role: "participant")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    cohort = Cohort.create!(name: "Private phrase release #{SecureRandom.hex(4)}", status: "active",
      created_by_user: owner, coach_workspace: workspace)
    config = persona_configuration(assistant_name: "Private phrase coach")
    phrase = persona_phrase_artifact(
      { "text" => "Participant private wording" },
      source_user_id: participant.id,
      provenance: "participant_supplied"
    )
    config["phrases"] = [ phrase ]
    persona = create_persona(creator: owner, name: "Private phrase persona #{SecureRandom.hex(4)}",
      workspace: workspace, config: config)
    persona_version = publish_persona(persona, actor: owner)
    CohortPersonaAssignment.create!(cohort: cohort, coach_workspace: workspace, coach_persona: persona,
      coach_persona_version: persona_version, assigned_by_user: owner)
    configuration = cohort.cohort_experience_configuration
    publisher = CohortExperience::Publisher.new(configuration: configuration, actor: owner)
    preview = publisher.preview!(expected_draft_revision: configuration.draft_revision)
    publisher.publish!(expected_preview_digest: preview, expected_draft_revision: configuration.reload.draft_revision,
      expected_current_version_id: nil)
    candidate = CohortReleases::CandidateBuilder.new(cohort: cohort, strict: true).call
    release = CohortReleases::Sealer.new(cohort: cohort, actor: owner).call!(
      request_key: "private-phrase", expected_bundle_digest: candidate.bundle_digest
    )

    snapshot = release.persona_snapshot
    refute snapshot.key?("config")
    refute_includes snapshot.to_json, phrase.fetch("text")
    refute_includes snapshot.to_json, "source_user_id"
    assert_equal persona_version.id, snapshot.fetch("version_id")
  end

  test "same-persona multi-cohort tool differences block user sealing and are counted during reconciliation" do
    owner, cohort, assignment, persona_version = governed_release_components
    workspace = cohort.coach_workspace
    second_cohort = Cohort.create!(name: "Ambiguous second #{SecureRandom.hex(4)}", status: "active",
      created_by_user: owner, coach_workspace: workspace)
    CohortPersonaAssignment.create!(cohort: second_cohort, coach_workspace: workspace,
      coach_persona: assignment.coach_persona, coach_persona_version: persona_version, assigned_by_user: owner)
    participant = persona_user(role: "participant")
    CohortMembership.create!(cohort: cohort, user: participant, role: "participant")
    CohortMembership.create!(cohort: second_cohort, user: participant, role: "participant")

    refute_equal Mia::Persona::NEUTRAL_ID,
      Mia::PersonaResolver.new(user: participant, cohort_membership: participant.cohort_memberships.find_by!(cohort: cohort)).call.id
    candidate = CohortReleases::CandidateBuilder.new(cohort: cohort, strict: true).call
    assert_equal 1, candidate.ambiguous_participant_count
    assert candidate.blockers.any? { |value| value.include?("conflicting active cohort configurations") }
    counts = CohortReleases::LegacyReconciler.new(scope: Cohort.where(id: cohort.id)).call
    assert_equal 1, counts.fetch(:ambiguous_cohorts)
    assert_equal 1, counts.fetch(:ambiguous_participants)
  end

  private

  def governed_release_components
    owner = persona_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    cohort = Cohort.create!(
      name: "Governed release #{SecureRandom.hex(4)}",
      status: "active",
      created_by_user: owner,
      coach_workspace: workspace
    )
    persona = create_persona(
      creator: owner,
      name: "Release persona #{SecureRandom.hex(4)}",
      workspace: workspace
    )
    persona_version = publish_persona(persona, actor: owner)
    assignment = CohortPersonaAssignment.create!(
      cohort: cohort,
      coach_workspace: workspace,
      coach_persona: persona,
      coach_persona_version: persona_version,
      assigned_by_user: owner
    )
    configuration = cohort.cohort_experience_configuration
    publisher = CohortExperience::Publisher.new(configuration: configuration, actor: owner)
    digest = publisher.preview!(expected_draft_revision: configuration.draft_revision)
    experience_version = publisher.publish!(
      expected_preview_digest: digest,
      expected_draft_revision: configuration.reload.draft_revision,
      expected_current_version_id: nil
    )
    [ owner, cohort, assignment, persona_version, experience_version ]
  end

  def duplicate_release(release, release_number:, request_key:)
    release.dup.tap do |copy|
      copy.release_number = release_number
      copy.request_key = request_key
      copy.request_fingerprint = Digest::SHA256.hexdigest(request_key)
      copy.released_at = Time.current
      rebuild_release_manifest!(copy)
    end
  end

  def rebuild_release_bundle!(release)
    release.persona_snapshot_digest = CohortReleases::Contract.digest(release.persona_snapshot)
    release.experience_snapshot_digest = CohortReleases::Contract.digest(release.experience_snapshot)
    release.tool_registry_digest = CohortReleases::Contract.digest(release.tool_registry_snapshot)
    release.bundle = CohortReleases::Contract.bundle(
      cohort: release.cohort,
      persona_snapshot: release.persona_snapshot,
      experience_snapshot: release.experience_snapshot,
      tool_registry_snapshot: release.tool_registry_snapshot
    )
    release.bundle_digest = CohortReleases::Contract.digest(release.bundle)
  end

  def rebuild_release_manifest!(release)
    release.manifest = CohortReleases::Contract.manifest(
      release_number: release.release_number,
      publication_source: release.publication_source,
      event_type: release.event_type,
      released_by_user_id: release.released_by_user_id,
      actor_role_snapshot: release.actor_role_snapshot,
      source_release_id: release.source_release_id,
      request_key: release.request_key,
      request_fingerprint: release.request_fingerprint,
      released_at: release.released_at,
      bundle_digest: release.bundle_digest
    )
    release.manifest_digest = CohortReleases::Contract.digest(release.manifest)
  end
end
