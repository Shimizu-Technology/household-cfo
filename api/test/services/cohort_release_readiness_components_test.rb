require "test_helper"

class CohortReleaseReadinessComponentsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "clerk_ready_#{SecureRandom.hex(4)}", email: "ready-#{SecureRandom.hex(4)}@example.com", role: "admin", invitation_status: "accepted")
    @cohort = Cohort.create!(created_by_user: @user, name: "Readiness components", status: "active")
  end

  test "each readiness check follows its own component's blockers, whatever the wording" do
    published = { "mode" => "published_version" }
    candidate = ->(by_component) do
      CohortReleases::CandidateBuilder::Candidate.new(
        cohort: @cohort, assignment: nil, persona: nil, persona_version: nil, experience_configuration: nil, experience_version: nil,
        brand_version: nil, persona_snapshot: published, experience_snapshot: published, brand_snapshot: published,
        tool_registry_snapshot: { "schema_version" => 1, "operations" => [] }, bundle: {}, bundle_digest: "x",
        blockers: by_component.values.flatten, warnings: [], ambiguous_participant_count: 0,
        blockers_by_component: { persona: [], experience: [], brand: [], tools: [] }.merge(by_component)
      )
    end
    serializer = CohortReleases::StudioSerializer.new(cohort: @cohort, actor: @user)
    ready = ->(by_component) { serializer.send(:readiness_checks, candidate.(by_component)).to_h { |check| [ check[:id], check[:ready] ] } }

    assert_equal({ "workspace_brand" => true, "assistant_voice" => true, "participant_tools" => true, "system_controls" => true, "participant_cohort" => true }, ready.({}))
    brand = ready.(brand: [ "Publish the program’s look before preparing a version for this group." ])
    assert_equal [ false, true ], [ brand["workspace_brand"], brand["assistant_voice"] ]
    voice = ready.(persona: [ "Publish Mia’s voice, with its safety checks, before preparing a version for this group." ])
    assert_equal [ true, false ], [ voice["workspace_brand"], voice["assistant_voice"] ]
    tools = ready.(experience: [ "Publish participant tools before preparing a version for this group." ], tools: [ "The selected tool contract could not validate its registered operation handlers." ])
    assert_equal [ false, false ], [ tools["participant_tools"], tools["system_controls"] ]
  end
end
