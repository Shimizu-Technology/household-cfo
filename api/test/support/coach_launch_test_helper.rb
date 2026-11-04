require_relative "persona_test_helper"

module CoachLaunchTestHelper
  include PersonaTestHelper

  def prepare_launch
    @owner = persona_user
    @workspace = CoachWorkspaces::Provisioner.ensure_for!(@owner)
    config = persona_configuration.merge("phrases" => [ persona_phrase_artifact({ "text" => "One step", "meaning" => "Choose one manageable next step." }, source_user_id: @owner.id) ])
    @persona = create_persona(creator: @owner, workspace: @workspace, config:)
    brand = @workspace.workspace_brand_configuration
    brand.update!(draft_config: brand.draft_config.merge("product_name" => "Reviewed launch appearance"))
    @groups = 2.times.map { |n| Cohort.create!(name: "Launch group #{n}", status: "active", created_by_user: @owner, coach_workspace: @workspace) }
    @groups.each do |cohort|
      config = cohort.cohort_experience_configuration
      config.update!(draft_config: CohortExperience::Schema.upgrade(config.draft_config).merge("experience_mode" => "savings_challenge"))
    end
    Mia::PersonaPublisher.new(persona: @persona, actor: @owner).preview!(expected_draft_revision: @persona.draft_revision)
    candidate = Mia::PersonaRelease::CandidateBuilder.new(persona: @persona, actor: @owner).call!
    Mia::PersonaRelease::BehavioralPreviewRecorder.new(persona: @persona, actor: @owner).call!(candidate:, preview: {
      status: "ready", source: "live_model", sample_prompt: "Help this fictional household plan.", sample_reply: "Review the confirmed plan and choose one next step.",
      model_identifier: "test-model", provider_request_id: "gen-test-helper", context_digest: Mia::PersonaPreviewer.context_digest
    })
    Mia::PersonaRelease::Runner.new(persona: @persona, actor: @owner).call!
    @review = build_review
  end

  def publish(review: @review, request_key: "one-launch")
    CoachLaunches::Publisher.new(persona: @persona.reload, actor: @owner, review:, request_key:).call!
  end

  def config_review(config, publisher)
    digest = publisher.new(configuration: config, actor: @owner).preview!(expected_draft_revision: config.draft_revision)
    { "draft_revision" => config.reload.draft_revision, "published_version_id" => config.current_published_version_id, "preview_digest" => digest }
  end

  def build_review
    ready = Mia::PersonaRelease::Readiness.new(persona: @persona.reload, actor: @owner).call.deep_stringify_keys
    {
      "persona" => { "id" => @persona.id, "draft_revision" => @persona.draft_revision, "published_version_id" => @persona.current_published_version_id, "voice_changes" => Mia::PersonaStudioSerializer.new(@persona, policy: Mia::PersonaStudioPolicy.new(@owner, workspace: @workspace)).detail[:has_unpublished_changes], "preview_digest" => @persona.preview_digest }.merge(ready.slice("candidate", "evaluation_run", "behavioral_preview_evidence")),
      "brand" => config_review(@workspace.workspace_brand_configuration, Branding::Publisher),
      "tools" => @groups.map { |c| config_review(c.cohort_experience_configuration, CohortExperience::Publisher).merge("id" => c.id) },
      "groups" => @groups.map do |c|
        rollout = CohortRollouts::StudioSerializer.new(cohort: c.reload, actor: @owner).call
        candidate = CohortReleases::StudioSerializer.new(cohort: c, actor: @owner).call.dig(:readiness, :candidate)
        { "id" => c.id, "name" => c.name, "bundle_digest" => candidate[:bundle_digest], "roster_digest" => rollout.dig(:current_roster, :digest), "participant_ids" => rollout.dig(:current_roster, :participants).map { |p| p[:user_id] }, "active_release_id" => c.active_cohort_release_id, "assignment_persona_id" => c.cohort_persona_assignment&.coach_persona_id }
      end
    }
  end
end
