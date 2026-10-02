# frozen_string_literal: true

require "test_helper"
require_relative "../../db/migrate/20261003030000_make_persona_restores_and_audience_reviews_append_only"
require_relative "../support/persona_test_helper"

class MakePersonaRestoresAndAudienceReviewsAppendOnlyTest < ActiveSupport::TestCase
  include PersonaTestHelper

  test "append-only release evidence and draft restore storage are constrained" do
    connection = ActiveRecord::Base.connection

    assert connection.data_source_exists?(:coach_persona_draft_restore_events)
    restore_foreign_keys = connection.foreign_keys(:coach_persona_draft_restore_events)
    assert_equal %w[coach_persona_versions coach_personas users], restore_foreign_keys.map(&:to_table).sort
    assert connection.indexes(:coach_persona_draft_restore_events).any? do |index|
      index.unique && index.name == "idx_persona_draft_restore_events_digest"
    end
    assert_includes connection.check_constraints(:coach_persona_draft_restore_events).map(&:name),
      "persona_draft_restore_events_revision_sequence"

    effective_index = connection.indexes(:coach_phrase_audience_attestations)
      .find { |index| index.name == "idx_phrase_audience_attestations_effective" }
    assert effective_index
    assert_equal false, effective_index.unique
    assert_equal %w[coach_persona_release_candidate_id artifact_id reviewed_at id], effective_index.columns
    refute connection.indexes(:coach_phrase_audience_attestations)
      .any? { |index| index.name == "idx_phrase_audience_attestations_artifact" }

    %i[coach_persona_versions coach_persona_publication_events].each do |table|
      column = connection.columns(table).find { |candidate| candidate.name == "phrase_audience_attestation_digests" }
      assert column
      refute column.null
      assert_equal [], JSON.parse(column.default)
    end
    assert connection.columns(:coach_persona_behavioral_preview_evidences)
      .any? { |column| column.name == "provider_request_id" }
  end

  test "existing gate v2 versions and events backfill the exact audience review digests" do
    owner = persona_user
    config = persona_configuration(assistant_name: "Audience evidence backfill")
    config["phrases"] = [
      persona_phrase_artifact(
        { "text" => "Håfa adai", "meaning" => "The coach's reviewed greeting." },
        source_user_id: owner.id
      )
    ]
    persona = create_persona(creator: owner, config: config)
    version = publish_persona(persona, actor: owner)
    event = persona.publication_events.order(:id).last
    expected = version.phrase_audience_attestation_digests
    assert_equal 1, expected.length
    version.update_column(:phrase_audience_attestation_digests, [])
    event.update_column(:phrase_audience_attestation_digests, [])

    MakePersonaRestoresAndAudienceReviewsAppendOnly.new
      .send(:backfill_phrase_audience_attestation_digests)

    assert_equal expected, version.reload.phrase_audience_attestation_digests
    assert_equal expected, event.reload.phrase_audience_attestation_digests
  end


  test "pristine downgrade and re-upgrade succeeds before append-only evidence is used" do
    assert_empty CoachPhraseAudienceAttestation.all
    assert_empty CoachPersonaBehavioralPreviewEvidence.all
    assert_empty CoachPersonaDraftRestoreEvent.all
    migration = MakePersonaRestoresAndAudienceReviewsAppendOnly.new
    migrated_down = false

    migration.suppress_messages { migration.migrate(:down) }
    migrated_down = true
    connection = ActiveRecord::Base.connection
    connection.schema_cache.clear!
    refute connection.data_source_exists?(:coach_persona_draft_restore_events)
    refute connection.column_exists?(:coach_persona_behavioral_preview_evidences, :provider_request_id)
    old_index = connection.indexes(:coach_phrase_audience_attestations)
      .find { |index| index.name == "idx_phrase_audience_attestations_artifact" }
    assert old_index&.unique

    migration.suppress_messages { migration.migrate(:up) }
    migrated_down = false
    connection.schema_cache.clear!
    assert connection.data_source_exists?(:coach_persona_draft_restore_events)
    provider_column = connection.columns(:coach_persona_behavioral_preview_evidences)
      .find { |column| column.name == "provider_request_id" }
    assert provider_column
    refute provider_column.null
    assert connection.indexes(:coach_phrase_audience_attestations)
      .any? { |index| index.name == "idx_phrase_audience_attestations_effective" && !index.unique }
  ensure
    migration&.suppress_messages { migration.migrate(:up) } if migrated_down
    ActiveRecord::Base.connection.schema_cache.clear!
  end


  test "downgrade refuses to remove behavioral preview provenance and leaves schema and rows intact" do
    owner = persona_user
    persona = create_persona(creator: owner)
    candidate = Mia::PersonaRelease::CandidateBuilder.new(persona: persona, actor: owner).call!
    evidence = Mia::PersonaRelease::BehavioralPreviewRecorder.new(persona: persona, actor: owner).call!(
      candidate: candidate,
      preview: {
        status: "ready", source: "live_model", sample_prompt: "Test this fictional household.",
        sample_reply: "Review the exact facts and choose one step.", model_identifier: "test-model",
        provider_request_id: "gen-migration-preview", context_digest: Mia::PersonaPreviewer.context_digest
      }
    )
    assert_empty CoachPhraseAudienceAttestation.all
    assert_empty CoachPersonaDraftRestoreEvent.all
    snapshot = evidence.attributes

    error = downgrade_error
    assert_includes error.message, "behavioral preview provider provenance"
    assert_equal snapshot, evidence.reload.attributes
    assert_current_schema_intact
  end

  test "downgrade refuses to remove draft restore events and leaves schema and rows intact" do
    owner = persona_user
    persona = create_persona(creator: owner)
    first_config = persona.draft_config.deep_dup
    first_version = legacy_version(persona, owner, first_config, 1)
    second_config = first_config.deep_merge("voice" => { "energy" => "Warm and encouraging." })
    persona.update!(draft_config: second_config)
    second_version = legacy_version(persona, owner, second_config, 2)
    persona.update!(current_published_version: second_version)
    event = Mia::PersonaRollback.new(persona: persona, target_version: first_version, actor: owner).call(
      expected_current_version_id: second_version.id,
      expected_draft_revision: persona.draft_revision
    )
    assert_empty CoachPhraseAudienceAttestation.all
    assert_empty CoachPersonaBehavioralPreviewEvidence.all
    snapshot = event.attributes

    error = downgrade_error
    assert_includes error.message, "draft restore audit events"
    assert_equal snapshot, event.reload.attributes
    assert_current_schema_intact
  end

  test "downgrade refuses to collapse superseding audience reviews and leaves schema and rows intact" do
    owner = persona_user
    config = persona_configuration(assistant_name: "Irreversible audience review")
    config["phrases"] = [
      persona_phrase_artifact(
        { "text" => "Håfa adai", "meaning" => "A reviewed greeting." },
        source_user_id: owner.id
      )
    ]
    persona = create_persona(creator: owner, config: config)
    version = publish_persona(persona, actor: owner)
    candidate = version.release_candidate
    artifact = candidate.phrase_artifacts_snapshot.sole
    Mia::PersonaRelease::AudienceAttester.new(persona: persona, actor: owner).call!(
      candidate_digest: candidate.manifest_digest,
      artifact_id: artifact.fetch("artifact_id"),
      artifact_fingerprint: artifact.fetch("fingerprint"),
      decision: "rejected"
    )
    reviews = candidate.phrase_audience_attestations.order(:id).pluck(:id, :decision, :attestation_digest)
    assert_equal %w[approved rejected], reviews.map(&:second)

    preview_rows = CoachPersonaBehavioralPreviewEvidence.order(:id).map(&:attributes)
    error = downgrade_error
    assert_includes error.message, "multiple audience review audit records"
    assert_equal reviews, candidate.phrase_audience_attestations.order(:id).pluck(:id, :decision, :attestation_digest)
    assert_equal preview_rows, CoachPersonaBehavioralPreviewEvidence.order(:id).map(&:attributes)

    assert_current_schema_intact
  end

  private

  def downgrade_error
    migration = MakePersonaRestoresAndAudienceReviewsAppendOnly.new
    assert_raises(ActiveRecord::IrreversibleMigration) do
      migration.suppress_messages { migration.migrate(:down) }
    end
  end

  def assert_current_schema_intact
    connection = ActiveRecord::Base.connection
    connection.schema_cache.clear!
    assert connection.data_source_exists?(:coach_persona_draft_restore_events)
    provider_column = connection.columns(:coach_persona_behavioral_preview_evidences)
      .find { |column| column.name == "provider_request_id" }
    assert provider_column
    refute provider_column.null
    assert connection.column_exists?(:coach_persona_versions, :phrase_audience_attestation_digests)
    assert connection.column_exists?(:coach_persona_publication_events, :phrase_audience_attestation_digests)
    assert connection.indexes(:coach_phrase_audience_attestations)
      .any? { |index| index.name == "idx_phrase_audience_attestations_effective" && !index.unique }
    refute connection.indexes(:coach_phrase_audience_attestations)
      .any? { |index| index.name == "idx_phrase_audience_attestations_artifact" }
  end

  def legacy_version(persona, owner, config, version_number)
    version = persona.versions.create!(
      version_number: version_number,
      config: config,
      config_digest: Mia::PersonaSchema.digest(config),
      content_manifest_digest: CoachPersonaVersion.content_manifest_digest_for([]),
      phrase_manifest_digest: Mia::PhraseManifest.digest_for([]),
      published_by_user: owner,
      release_gate_version: "gate_v1"
    )
    version.seal_manifests!
  end
end
