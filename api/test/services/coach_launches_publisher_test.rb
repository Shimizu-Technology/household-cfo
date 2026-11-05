require "test_helper"
require_relative "../support/coach_launch_test_helper"

class CoachLaunchesPublisherTest < ActiveSupport::TestCase
  include CoachLaunchTestHelper
  setup do
    prepare_launch
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

  test "rejected audience phrases cannot be approved by the overall launch" do
    ready = Mia::PersonaRelease::Readiness.new(persona: @persona, actor: @owner).call
    phrase = ready.fetch(:phrase_audience_reviews).sole
    Mia::PersonaRelease::AudienceAttester.new(persona: @persona, actor: @owner).call!(candidate_digest: ready.dig(:candidate, :manifest_digest), artifact_id: phrase.fetch(:artifact_id), artifact_fingerprint: phrase.fetch(:artifact_fingerprint), decision: "rejected")
    assert_no_difference [ "CoachPersonaVersion.count", "WorkspaceBrandVersion.count", "CoachPhraseAudienceAttestation.count" ] do
      error = assert_raises(CoachLaunches::Publisher::Conflict) { publish }
      assert_includes error.message, "rejected"
    end
  end

  { missing_result: { result: nil }, long_key: { request_key: "k" * 65 }, invalid_digest: { request_digest: "not-a-digest" }, invalid_result: { result: [] } }.each do |label, invalid|
    test "database rejects malformed launch receipts #{label}" do
      input = { coach_workspace: @workspace, user: @owner, coach_persona: @persona, request_key: "shape-proof", request_digest: "a" * 64 }
      input[:result] = { "status" => "not_committed" } unless label == :missing_result
      input.merge!(invalid.except(:result))
      input[:result] = invalid[:result] if label == :invalid_result
      assert_raises(ActiveRecord::StatementInvalid) do
        CoachLaunchReceipt.transaction(requires_new: true) { CoachLaunchReceipt.create!(input) }
      end
    end
  end

  test "replay rechecks authority" do
    publish
    @workspace.coach_workspace_memberships.find_by!(user: @owner).update!(role: "editor")
    assert_raises(ActiveRecord::RecordNotFound) { publish }
  end
end

class CoachLaunchesReadinessTest < ActiveSupport::TestCase
  include CoachLaunchTestHelper
  setup do
    prepare_launch
    publish
  end

  [ false, true ].each do |changed|
    test "participant conflicts block #{changed ? 'a new bundle' : 'an active bundle with no seal needed'}" do
      participant = persona_user(role: "participant")
      @groups.each { |cohort| participant.cohort_memberships.create!(cohort:, role: "participant") }
      if changed
        brand = @workspace.workspace_brand_configuration.reload
        brand.update!(draft_config: brand.draft_config.merge("product_name" => "Blocked appearance"))
      end
      @review = build_review
      studio = CohortReleases::StudioSerializer.new(cohort: @groups.first.reload, actor: @owner).call
      refute studio.dig(:readiness, :ready)
      refute studio.dig(:readiness, :seal_needed)
      assert_no_difference [ "CoachLaunchReceipt.count", "CohortRelease.count", "WorkspaceBrandVersion.count", "CohortReleaseActivationEvent.count" ] do
        assert_raises(CoachLaunches::Publisher::Conflict) { publish(request_key: "blocked-noop") }
      end
    end
  end
end

class CoachLaunchesRecoveryTest < ActiveSupport::TestCase
  include CoachLaunchTestHelper
  setup { prepare_launch }

  test "resolution returns the committed receipt without replaying or changing it" do
    result = publish
    assert_no_difference [ "CoachLaunchReceipt.count", "CoachPersonaVersion.count", "CohortRelease.count" ] do
      assert_equal({ status: "live", launch: result }, resolver.resolve!)
    end
  end

  test "negative resolution closes the key and prevents a delayed original request from launching" do
    assert_equal({ status: "not_committed" }, resolver.resolve!)
    assert_equal({ status: "not_committed" }, resolver.resolve!)
    assert_no_difference [ "CoachLaunchReceipt.count", "CoachPersonaVersion.count", "CohortRelease.count" ] do
      assert_raises(CoachLaunches::Publisher::Conflict) { publish }
    end
    assert_nil @groups.first.reload.active_cohort_release_id
    assert publish(request_key: "fresh-review")
  end

  test "resolution rechecks authority and exact persona and request evidence" do
    publish
    bad = @review.deep_merge("brand" => { "draft_revision" => 999 })
    assert_raises(CoachLaunches::Publisher::Conflict) { resolver(review: bad).resolve! }
    @workspace.coach_workspace_memberships.find_by!(user: @owner).update!(role: "editor")
    assert_raises(ActiveRecord::RecordNotFound) { resolver.resolve! }
  end

  private

  def resolver(review: @review)
    CoachLaunches::Publisher.new(persona: @persona.reload, actor: @owner, review:, request_key: "one-launch")
  end
end
