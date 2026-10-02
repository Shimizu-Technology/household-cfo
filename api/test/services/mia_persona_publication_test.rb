# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class MiaPersonaPublicationTest < ActiveSupport::TestCase
  include PersonaTestHelper

  setup do
    @coach = persona_user
    @persona = create_persona(creator: @coach)
    @publisher = Mia::PersonaPublisher.new(persona: @persona, actor: @coach)
  end

  test "compiling a draft does not record a publishable behavioral preview" do
    preview = @publisher.compile_preview!(expected_draft_revision: 1)

    assert preview.fetch(:prompt).present?
    assert_match(/\A[0-9a-f]{64}\z/, preview.fetch(:digest))
    assert_nil @persona.reload.preview_digest
    assert_nil @persona.previewed_at
    assert_nil @persona.previewed_draft_revision
    error = assert_raises(Mia::PersonaPublisher::PublicationError) do
      @publisher.publish!(expected_preview_digest: preview.fetch(:digest), expected_draft_revision: 1, expected_current_version_id: nil)
    end
    assert_equal "Preview this exact draft before publishing", error.message
  end

  test "compiling again preserves a prior successful preview of the same draft" do
    preview = @publisher.preview!(expected_draft_revision: 1)
    previewed_at = @persona.previewed_at

    assert_equal preview, @publisher.compile_preview!(expected_draft_revision: 1)
    assert_equal preview.fetch(:digest), @persona.reload.preview_digest
    assert_equal previewed_at, @persona.previewed_at
  end

  test "publish requires the exact compiled preview revision and current version" do
    preview = @publisher.preview!(expected_draft_revision: 1)

    assert_raises(Mia::PersonaPublisher::PublicationError) do
      @publisher.publish!(
        expected_preview_digest: "0" * 64,
        expected_draft_revision: 1,
        expected_current_version_id: nil
      )
    end

    version = publish_with_evidence(preview: preview, expected_version_id: nil)

    assert_equal 1, version.version_number
    assert_equal Mia::PersonaSchema.digest(@persona.draft_config), version.config_digest
    assert_equal version, @persona.reload.current_published_version
    assert_equal preview.fetch(:digest), @persona.preview_digest
    assert_equal 1, @persona.previewed_draft_revision
    assert_equal "publish", @persona.publication_events.sole.event_type
  end

  test "draft edit after preview cannot be published with stale revision or digest" do
    preview = @publisher.preview!(expected_draft_revision: 1)
    @persona.update!(draft_config: @persona.draft_config.deep_merge("voice" => { "energy" => "Direct and energetic." }))

    error = assert_raises(Mia::PersonaPublisher::PublicationError) do
      @publisher.publish!(
        expected_preview_digest: preview.fetch(:digest),
        expected_draft_revision: 1,
        expected_current_version_id: nil
      )
    end

    assert_includes error.message, "draft changed"
  end

  test "publish atomically advances assignments while historical messages retain attribution" do
    first = publish_current
    cohort = Cohort.create!(name: "Persona cohort", status: "active", created_by_user: @coach)
    assignment = CohortPersonaAssignment.create!(cohort: cohort, coach_persona: @persona, assigned_by_user: @coach)
    participant = persona_user(role: "participant")
    household = Household.create!(created_by_user: participant, name: "Persona household")
    message = household.chat_sessions.create!(user: participant, title: "Ask Mia").chat_messages.create!(
      role: "assistant",
      content: "A versioned answer.",
      coach_persona_version: first,
      assistant_author: "Mia"
    )

    @persona.update!(draft_config: @persona.draft_config.deep_merge("voice" => { "energy" => "Steady and reassuring." }))
    preview = @publisher.preview!(expected_draft_revision: 2)
    second = publish_with_evidence(preview: preview, expected_version_id: first.id)

    assert_equal second, assignment.reload.coach_persona_version
    assert_equal first, message.reload.coach_persona_version
    assert_equal "Mia", message.as_api_json.fetch(:author)
  end

  test "published versions and publication events cannot be changed or deleted" do
    version = publish_current
    event = @persona.publication_events.sole

    refute version.update(config_digest: "f" * 64)
    assert_includes version.errors[:base], "published persona versions are immutable"
    assert_raises(ActiveRecord::DeleteRestrictionError) { version.destroy }
    refute event.update(event_type: "rollback")
    assert_includes event.errors[:base], "publication events are immutable"
    refute event.destroy
  end

  test "restore copies a target into the draft without publishing or advancing assignments" do
    first = publish_current
    cohort = Cohort.create!(name: "Rollback cohort", status: "active", created_by_user: @coach)
    assignment = CohortPersonaAssignment.create!(cohort: cohort, coach_persona: @persona, assigned_by_user: @coach)
    @persona.update!(
      draft_config: @persona.draft_config.deep_merge(
        "identity" => { "assistant_name" => "New assistant name" },
        "voice" => { "energy" => "Warm and encouraging." }
      )
    )
    preview = @publisher.preview!(expected_draft_revision: 2)
    second = publish_with_evidence(preview: preview, expected_version_id: first.id)

    version_count = @persona.versions.count
    publication_event_count = @persona.publication_events.count
    restored = Mia::PersonaRollback.new(persona: @persona, target_version: first, actor: @coach).call(
      expected_current_version_id: second.id,
      expected_draft_revision: @persona.draft_revision
    )

    assert_equal first, restored.source_version
    assert restored.integrity_valid?
    @persona.reload
    assert_equal second, @persona.current_published_version
    assert_equal first.config, @persona.draft_config
    assert_equal first.config.dig("identity", "assistant_name"), @persona.name
    assert_equal 3, @persona.draft_revision
    assert_nil @persona.preview_digest
    assert_nil @persona.previewed_at
    assert_nil @persona.previewed_draft_revision
    assert_equal second, assignment.reload.coach_persona_version
    assert_equal version_count, @persona.versions.count
    assert_equal publication_event_count, @persona.publication_events.count
    assert_equal restored, @persona.draft_restore_events.sole
    refute restored.update(config_digest: "f" * 64)
    assert_includes restored.errors[:base], "draft restore events are immutable"
    refute restored.destroy
    restored.update_column(:event_digest, "f" * 64)
    refute restored.reload.integrity_valid?
  end

  test "restore rejects the current version and a draft that already matches the target" do
    first = publish_current
    current_error = assert_raises(Mia::PersonaRollback::RollbackError) do
      Mia::PersonaRollback.new(persona: @persona, target_version: first, actor: @coach).call(
        expected_current_version_id: first.id,
        expected_draft_revision: @persona.draft_revision
      )
    end
    assert_equal "The current published version cannot be restored to the draft", current_error.message

    @persona.update!(draft_config: @persona.draft_config.deep_merge("voice" => { "energy" => "Warm and encouraging." }))
    second = publish_current
    Mia::PersonaRollback.new(persona: @persona, target_version: first, actor: @coach).call(
      expected_current_version_id: second.id,
      expected_draft_revision: @persona.draft_revision
    )
    noop_error = assert_raises(Mia::PersonaRollback::RollbackError) do
      Mia::PersonaRollback.new(persona: @persona, target_version: first, actor: @coach).call(
        expected_current_version_id: second.id,
        expected_draft_revision: @persona.reload.draft_revision
      )
    end
    assert_equal "The draft already matches this version", noop_error.message
  end

  test "unpublished and archived personas cannot be assigned" do
    cohort = Cohort.create!(name: "Draft cohort", status: "draft", created_by_user: @coach)
    assignment = CohortPersonaAssignment.new(cohort: cohort, coach_persona: @persona, assigned_by_user: @coach)
    refute assignment.valid?
    assert_includes assignment.errors[:coach_persona], "must be active and published before assignment"

    publish_current
    @persona.archive!
    refute assignment.valid?
  end

  test "current version conflicts prevent stale rollback" do
    first = publish_current

    error = assert_raises(Mia::PersonaRollback::RollbackError) do
      Mia::PersonaRollback.new(persona: @persona, target_version: first, actor: @coach).call(
        expected_current_version_id: nil,
        expected_draft_revision: @persona.draft_revision
      )
    end

    assert_includes error.message, "published persona changed"
  end

  private

  def publish_current
    preview = @publisher.preview!(expected_draft_revision: @persona.reload.draft_revision)
    publish_with_evidence(preview: preview, expected_version_id: @persona.current_published_version_id)
  end

  def publish_with_evidence(preview:, expected_version_id:)
    @publisher.publish!(
      expected_preview_digest: preview.fetch(:digest),
      expected_draft_revision: @persona.draft_revision,
      expected_current_version_id: expected_version_id,
      **persona_release_evidence(@persona, actor: @coach)
    )
  end
end
