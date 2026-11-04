require "test_helper"
require_relative "../support/persona_test_helper"

class MiaProgramDefaultTest < ActiveSupport::TestCase
  include PersonaTestHelper

  setup do
    @coach = persona_user
    @participant = persona_user(role: "participant")
    @cohort = cohort_for(@coach, name: "Program default")
    @membership = @cohort.cohort_memberships.create!(user: @participant, role: "participant")
  end

  test "one published program voice is selected for participant phrase scoping" do
    persona = create_persona(creator: @coach, config: persona_configuration(assistant_name: "Mia #{SecureRandom.hex(3)}"))
    version = publish_persona(persona, actor: @coach)
    persona_runtime = resolve_persona
    assert_equal version.id, persona_runtime.version_id
    assert_equal @participant.id, persona_runtime.send(:participant_id)
    assert_nil @cohort.cohort_persona_assignment
  end

  test "a program that has never gone live uses the neutral voice" do
    persona = create_persona(creator: @coach, config: persona_configuration(assistant_name: "Mia #{SecureRandom.hex(3)}"))
    publish_persona(persona, actor: @coach)
    assert_equal Mia::Persona::NEUTRAL_ID, resolve.persona.id
  end

  test "a program that has never gone live uses the standalone tool settings" do
    configuration = @cohort.cohort_experience_configuration
    config = CohortExperience::Schema.upgrade(configuration.draft_config)
    config["optional_modules"] = CohortExperience::Schema::CONFIGURABLE_MODULES.index_with(false)
    configuration.update!(draft_config: config, last_edited_by_user: @coach)
    publisher = CohortExperience::Publisher.new(configuration: configuration, actor: @coach)
    digest = publisher.preview!(expected_draft_revision: configuration.draft_revision)
    publisher.publish!(expected_preview_digest: digest, expected_draft_revision: configuration.draft_revision, expected_current_version_id: nil)
    expected = CohortExperience::EffectiveCapabilitiesResolver.safe_default_payload(cohort_membership: @membership, standalone: true)
    assert_equal expected, resolve.capabilities
  end

  test "none or multiple published voices use neutral but unpublished drafts do not make it ambiguous" do
    assert_equal Mia::Persona::NEUTRAL_ID, resolve_persona.id
    first = create_persona(creator: @coach, config: persona_configuration(assistant_name: "Mia #{SecureRandom.hex(3)}"))
    version = publish_persona(first, actor: @coach)
    second = create_persona(creator: @coach, config: persona_configuration(assistant_name: "Mia #{SecureRandom.hex(3)}"))
    assert_equal version.id, resolve_persona.version_id
    publish_persona(second, actor: @coach)
    assert_equal Mia::Persona::NEUTRAL_ID, resolve_persona.id
  end

  test "explicit assignment wins over ambiguous program voices and stale assignment stays neutral" do
    first = create_persona(creator: @coach, config: persona_configuration(assistant_name: "Mia #{SecureRandom.hex(3)}"))
    first_version = publish_persona(first, actor: @coach)
    publish_persona(create_persona(creator: @coach, config: persona_configuration(assistant_name: "Mia #{SecureRandom.hex(3)}")), actor: @coach)
    assignment = CohortPersonaAssignment.create!(cohort: @cohort, coach_persona: first, assigned_by_user: @coach)
    assert_equal first_version.id, resolve_persona.version_id
    first.update!(draft_config: first.draft_config.deep_merge("voice" => { "energy" => "Steady and reassuring." }))
    publish_persona(first, actor: @coach)
    assignment.update_column(:coach_persona_version_id, first_version.id)
    assert_equal Mia::Persona::NEUTRAL_ID, resolve_persona.id
  end

  test "new releases seal inherited voice and never follow later program publication" do
    persona = create_persona(creator: @coach, config: persona_configuration(assistant_name: "Mia #{SecureRandom.hex(3)}"))
    version = publish_persona(persona, actor: @coach)
    candidate = CohortReleases::CandidateBuilder.new(cohort: @cohort, strict: false).call
    assert_equal version, candidate.persona_version
    CohortReleases::LegacyReconciler.new(scope: Cohort.where(id: @cohort.id)).call
    release = @cohort.reload.cohort_releases.sole
    assert release.integrity_valid?, release.integrity_report.inspect
    @cohort.update!(active_cohort_release: release)
    assert_equal version.id, resolve.persona.version_id
    persona.update!(draft_config: persona.draft_config.deep_merge("voice" => { "energy" => "Steady and reassuring." }))
    publish_persona(persona, actor: @coach)
    assert_equal version.id, resolve.persona.version_id
    assert release.reload.integrity_valid?
  end

  test "a neutral sealed release stays neutral after the program publishes a voice" do
    CohortReleases::LegacyReconciler.new(scope: Cohort.where(id: @cohort.id)).call
    @cohort.update!(active_cohort_release: @cohort.cohort_releases.sole)
    publish_persona(create_persona(creator: @coach, config: persona_configuration(assistant_name: "Mia #{SecureRandom.hex(3)}")), actor: @coach)
    assert_equal Mia::Persona::NEUTRAL_ID, resolve.persona.id
  end

  test "archived or other program voices never become a program default" do
    persona = create_persona(creator: @coach)
    publish_persona(persona, actor: @coach)
    persona.archive!
    other = persona_user
    publish_persona(create_persona(creator: other), actor: other)
    assert_equal Mia::Persona::NEUTRAL_ID, resolve_persona.id
  end

  test "conflicting inherited voices retain the ambiguity fallback" do
    publish_persona(create_persona(creator: @coach), actor: @coach)
    other = persona_user
    publish_persona(create_persona(creator: other), actor: other)
    second = cohort_for(other, name: "Another program")
    second.cohort_memberships.create!(user: @participant, role: "participant")
    assert_equal Mia::Persona::NEUTRAL_ID, resolve_persona.id
    assert_equal 1, CohortReleases::ParticipantConflicts.new(cohort: @cohort).entries.length
  end

  test "conflict detection batches assignments and program voices across many memberships" do
    persona = create_persona(creator: @coach)
    publish_persona(persona, actor: @coach)
    5.times do |index|
      cohort_for(@coach, name: "Program group #{index}").cohort_memberships.create!(user: @participant, role: "participant")
    end
    queries = []
    recorder = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
    resolver = Mia::PersonaResolver.new(user: @participant, cohort_membership: @membership)
    ActiveRecord::Base.uncached do
      ActiveSupport::Notifications.subscribed(recorder, "sql.active_record") do
        refute resolver.send(:conflicting_persona_assignments?)
      end
    end
    assert_equal 3, queries.length, queries.join("\n")
    assert_equal 1, queries.count { |sql| sql.include?('FROM "cohort_persona_assignments"') }
    assert_equal 1, queries.count { |sql| sql.include?('FROM "coach_personas"') }
  end

  private

  def resolve
    Mia::ParticipantRuntimeResolver.new(user: @participant, cohort_membership: @membership).call
  end

  def resolve_persona
    Mia::PersonaResolver.new(user: @participant, cohort_membership: @membership).call
  end
end
