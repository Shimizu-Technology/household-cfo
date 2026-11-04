require "test_helper"
require_relative "../support/persona_test_helper"

class CoachLaunchesPublisherTest < ActiveSupport::TestCase
  include PersonaTestHelper
  setup do
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

  test "atomic launch publishes every group and reports unopened challenges with idempotent replay" do
    result = publish
    assert result.fetch("groups").all? { |g| g.fetch("challenge_closed") }
    assert @persona.reload.published?
    @groups.each do |cohort|
      assert cohort.reload.active_cohort_release_id
      refute cohort.savings_challenge_enabled
      assert_equal 1, cohort.cohort_release_activation_events.count
      assert_equal @persona.current_published_version_id, cohort.active_cohort_release.coach_persona_version_id
    end
    assert_no_difference [ "CoachPersonaVersion.count", "CohortRelease.count", "CohortReleaseActivationEvent.count", "CoachLaunchReceipt.count" ] do
      assert_equal result, publish
    end
  end

  test "rejects stale draft evidence roster assignment and tools without partial publication" do
    invalid = [
      ->(r) { r["persona"]["draft_revision"] += 1 },
      ->(r) { r["persona"]["candidate"]["manifest_digest"] = "f" * 64 },
      ->(r) { r["persona"]["evaluation_run"]["run_digest"] = "f" * 64 },
      ->(r) { r["persona"]["behavioral_preview_evidence"]["digest"] = "f" * 64 },
      ->(r) { r["persona"]["voice_changes"] = false },
      ->(r) { r["groups"][0]["roster_digest"] = "f" * 64 },
      ->(r) { r["groups"][0]["assignment_persona_id"] = 999 },
      ->(r) { r["tools"].pop },
      ->(r) { r["brand"]["draft_revision"] += 1 }
    ]
    invalid.each do |mutation|
      review = @review.deep_dup
      mutation.call(review)
      assert_no_difference [ "CoachPersonaVersion.count", "CohortRelease.count", "WorkspaceBrandVersion.count", "CohortExperienceVersion.count" ] do
        assert_raises(CoachLaunches::Publisher::Conflict) { publish(review:) }
      end
    end
    publish
    assert_raises(CoachLaunches::Publisher::Conflict) { publish(review: @review.deep_merge("extra" => true)) }
  end

  test "interruption after each publication approval assignment seal and launch rolls back every group" do
    checkpoints = {
      Branding::Publisher => :publish!, CohortExperience::Publisher => :publish!,
      Mia::PersonaRelease::AudienceAttester => :call!, Mia::PersonaRelease::RunApprover => :call!, Mia::PersonaPublisher => :publish!,
      CohortPersonaAssignment => :update!, CoachOperations::Runner => :call!, CohortReleases::InitialLauncher => :call!
    }
    originals = checkpoints.to_h { |klass, method| [ klass, klass.instance_method(method) ] }
    observed = []
    interrupt_after = nil
    originals.each do |klass, original|
      klass.define_method(checkpoints.fetch(klass)) do |*args, **kwargs|
        result = original.bind_call(self, *args, **kwargs)
        observed << klass.name
        raise IOError, "Connection lost after #{klass.name}" if observed.length == interrupt_after

        result
      end
    end
    # brand + two tool publications + phrase review + evaluation approval + voice
    # publication + each group's assignment, seal and initial launch = 12 steps.
    1.upto(12) do |step|
      interrupt_after = step
      observed.clear
      counts = %w[CoachPersonaVersion CohortRelease WorkspaceBrandVersion CohortExperienceVersion CohortReleaseActivationEvent CoachLaunchReceipt CoachPhraseAudienceAttestation CoachPersonaEvaluationApproval CohortPersonaAssignment CoachOperationExecution].map { |name| "#{name}.count" }
      assert_no_difference counts do
        assert_raises(IOError, "step #{step}") { publish }
      end
      assert_equal step, observed.length
      assert @groups.all? { |cohort| cohort.reload.active_cohort_release_id.nil? }
      assert_nil @persona.reload.current_published_version_id
    end
    interrupt_after = nil
    observed.clear
    publish
    assert_equal 12, observed.length
    assert_equal 2, CohortReleaseActivationEvent.count
  ensure
    originals&.each { |klass, original| klass.define_method(checkpoints.fetch(klass), original) }
  end

  test "a group completed after review cannot be assigned or published" do
    @groups.first.update!(status: "completed")
    assert_no_difference [ "CoachPersonaVersion.count", "WorkspaceBrandVersion.count", "CohortPersonaAssignment.count", "CoachLaunchReceipt.count" ] do
      assert_raises(CoachLaunches::Publisher::Conflict) { publish }
    end
    assert_nil @persona.reload.current_published_version_id
  end

  test "replay rechecks authority" do
    publish
    @workspace.coach_workspace_memberships.find_by!(user: @owner).update!(role: "editor")
    assert_raises(ActiveRecord::RecordNotFound) { publish }
  end

  test "later updates keep readiness gates and roll back every group when one participant is not ready" do
    participants = @groups.map do |cohort|
      user = persona_user(role: "participant")
      user.cohort_memberships.create!(cohort:, role: "participant")
      user
    end
    @review = build_review
    publish
    brand = @workspace.workspace_brand_configuration.reload
    brand.update!(draft_config: brand.draft_config.merge("product_name" => "A changed program"))
    @review = build_review
    participants.last.update!(invitation_status: "revoked")
    previous = @groups.map { |c| c.reload.active_cohort_release_id }
    assert_no_difference [ "CohortRelease.count", "WorkspaceBrandVersion.count", "CohortReleaseExposure.count", "CoachLaunchReceipt.count" ] do
      assert_raises(CohortRollouts::StateMachine::Ineligible) { CoachLaunches::Publisher.new(persona: @persona.reload, actor: @owner, review: @review, request_key: "later-launch").call! }
    end
    assert_equal previous, @groups.map { |c| c.reload.active_cohort_release_id }
    participants.last.update!(invitation_status: "accepted")
    result = CoachLaunches::Publisher.new(persona: @persona.reload, actor: @owner, review: @review, request_key: "later-launch").call!
    assert_equal 2, result.fetch("groups").length
    assert @groups.all? { |c| c.reload.active_cohort_release_id != previous[@groups.index(c)] }
  end

  private

  def publish(review: @review)
    CoachLaunches::Publisher.new(persona: @persona.reload, actor: @owner, review:, request_key: "one-launch").call!
  end

  def config_review(config, publisher)
    digest = publisher.new(configuration: config, actor: @owner).preview!(expected_draft_revision: config.draft_revision)
    { "draft_revision" => config.reload.draft_revision, "published_version_id" => config.current_published_version_id, "preview_digest" => digest }
  end

  def build_review
    ready = Mia::PersonaRelease::Readiness.new(persona: @persona.reload, actor: @owner).call.deep_stringify_keys
    {
      "persona" => { "id" => @persona.id, "draft_revision" => @persona.draft_revision, "published_version_id" => @persona.current_published_version_id, "voice_changes" => @persona.current_published_version_id.nil?, "preview_digest" => @persona.preview_digest }.merge(ready.slice("candidate", "evaluation_run", "behavioral_preview_evidence")),
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
