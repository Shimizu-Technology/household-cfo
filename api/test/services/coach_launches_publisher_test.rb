require "test_helper"
require_relative "../support/persona_test_helper"

class CoachLaunchesPublisherTest < ActiveSupport::TestCase
  include PersonaTestHelper
  setup do
    @owner = persona_user
    @workspace = CoachWorkspaces::Provisioner.ensure_for!(@owner)
    @persona = create_persona(creator: @owner, workspace: @workspace)
    @groups = 2.times.map { |n| Cohort.create!(name: "Launch group #{n}", status: "active", created_by_user: @owner, coach_workspace: @workspace) }
    @groups.each do |cohort|
      config = cohort.cohort_experience_configuration
      config.update!(draft_config: CohortExperience::Schema.upgrade(config.draft_config).merge("experience_mode" => "savings_challenge"))
    end
    Mia::PersonaPublisher.new(persona: @persona, actor: @owner).preview!(expected_draft_revision: @persona.draft_revision)
    persona_release_evidence(@persona, actor: @owner)
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

  test "interruption after every write phase rolls back all groups and retry publishes once" do
    interrupted = Class.new(CoachLaunches::Publisher) do
      attr_accessor :interrupt_after, :steps
      %i[publish_configuration! publish_voice! launch_group! operation!].each do |method|
        define_method(method) do |*args, **kwargs|
          result = super(*args, **kwargs)
          self.steps = (steps || 0) + 1
          raise IOError, "Browser connection lost" if steps == interrupt_after
          result
        end
        private method
      end
    end
    1.upto(8) do |step|
      worker = interrupted.new(persona: @persona.reload, actor: @owner, review: @review, request_key: "interrupted")
      worker.interrupt_after = step
      assert_no_difference [ "CoachPersonaVersion.count", "CohortRelease.count", "WorkspaceBrandVersion.count", "CohortExperienceVersion.count", "CohortReleaseActivationEvent.count", "CoachLaunchReceipt.count" ] do
        assert_raises(IOError, "step #{step}") { worker.call! }
      end
      assert @groups.all? { |cohort| cohort.reload.active_cohort_release_id.nil? }
      assert_nil @persona.reload.current_published_version_id
    end
    publish
    assert_equal 2, CohortReleaseActivationEvent.count
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
