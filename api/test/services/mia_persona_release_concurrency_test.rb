# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class MiaPersonaReleaseConcurrencyTest < ActiveSupport::TestCase
  include PersonaTestHelper

  class LiveTestAdapter < Mia::PersonaRelease::BehavioralAdapter
    def kind = "test_live_model"

    def call(evaluation_case:, persona:, candidate:)
      Response.new(output: "Review the exact candidate.", metadata: { "source" => "live_model" }, fallback_only: false)
    end
  end

  self.use_transactional_tests = false

  test "concurrent reviewers seal one immutable approval for a run" do
    owner = persona_user
    editor = persona_user
    reviewer = persona_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    workspace.coach_workspace_memberships.create!(user: editor, role: "editor")
    workspace.coach_workspace_memberships.create!(user: reviewer, role: "reviewer")
    persona = create_persona(creator: owner, workspace: workspace)
    run = Mia::PersonaRelease::Runner.new(persona: persona, actor: editor).call!
    remember(owner, editor, reviewer, workspace, persona)

    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads = [ owner.id, reviewer.id ].map do |actor_id|
      Thread.new do
        Thread.current.report_on_exception = false
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          begin
            record = Mia::PersonaRelease::RunApprover.new(
              run: CoachPersonaEvaluationRun.find(run.id), actor: User.find(actor_id)
            ).call!(decision: "approved", expected_run_digest: run.run_digest)
            results << record.id
          rescue StandardError => error
            results << error
          end
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.each(&:join)

    outcomes = 2.times.map { results.pop }
    assert outcomes.all? { |outcome| outcome.is_a?(Integer) }, -> { outcomes.inspect }
    assert_equal 1, outcomes.uniq.length
    assert_equal 1, CoachPersonaEvaluationApproval.where(coach_persona_evaluation_run_id: run.id).count
    assert CoachPersonaEvaluationApproval.find(outcomes.first).integrity_valid?
  ensure
    threads&.each { |thread| thread.join(2) }
    cleanup_records
  end

  test "publication holds the persona lock across evidence verification and version creation" do
    owner = persona_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    persona = create_persona(creator: owner, workspace: workspace)
    evaluation_case = persona.evaluation_cases.new(
      coach_workspace: workspace,
      created_by_user: owner,
      name: "Locking case",
      case_kind: "custom",
      prompt: "Can I afford this purchase?",
      assertions: [ { "type" => "not_fallback" } ],
      required: false,
      active: true,
      request_key: "locking-case-#{SecureRandom.uuid}",
      request_fingerprint: "d" * 64
    )
    evaluation_case.case_digest = CoachPersonaEvaluationCase.digest_for(evaluation_case)
    evaluation_case.save!
    preview = Mia::PersonaPublisher.new(persona: persona, actor: owner)
      .preview!(expected_draft_revision: persona.draft_revision)
    candidate = Mia::PersonaRelease::CandidateBuilder.new(persona: persona, actor: owner).call!
    behavioral = Mia::PersonaRelease::BehavioralPreviewRecorder.new(persona: persona, actor: owner).call!(
      candidate: candidate,
      preview: {
        status: "ready", source: "live_model", sample_prompt: "Review this fictional household.",
        sample_reply: "Review the exact candidate.", model_identifier: "test-model",
        context_digest: Mia::PersonaPreviewer.context_digest
      }
    )
    hybrid = Mia::PersonaRelease::HybridBehavioralAdapter.new(live: LiveTestAdapter.new)
    run = Mia::PersonaRelease::Runner.new(persona: persona, actor: owner, adapter: hybrid).call!
    approval = Mia::PersonaRelease::RunApprover.new(run: run, actor: owner).call!(
      decision: "approved", expected_run_digest: run.run_digest
    )
    remember(owner, nil, nil, workspace, persona)

    evidence_checked = Queue.new
    release_publish = Queue.new
    publish_result = Queue.new
    original_verify = Mia::PersonaRelease::Evidence.instance_method(:verify_current!)
    Mia::PersonaRelease::Evidence.define_method(:verify_current!) do |**keywords|
      result = original_verify.bind_call(self, **keywords)
      evidence_checked << true
      release_publish.pop
      result
    end
    publisher = Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection do
        begin
          locked_persona = CoachPersona.find(persona.id)
          version = Mia::PersonaPublisher.new(persona: locked_persona, actor: User.find(owner.id)).publish!(
            expected_preview_digest: preview.fetch(:digest),
            expected_draft_revision: locked_persona.draft_revision,
            expected_current_version_id: nil,
            expected_release_candidate_digest: run.release_candidate.manifest_digest,
            expected_evaluation_run_digest: run.run_digest,
            expected_evaluation_approval_digest: approval.approval_digest,
            expected_behavioral_preview_digest: behavioral.evidence_digest
          )
          publish_result << version.id
        rescue StandardError => error
          publish_result << error
        end
      end
    end
    evidence_checked.pop

    connection = ActiveRecord::Base.connection
    connection.execute("SET lock_timeout = '500ms'")
    assert_raises ActiveRecord::LockWaitTimeout do
      CoachPersona.find(persona.id).with_lock do
        CoachPersonaEvaluationCase.find(evaluation_case.id).retire!(actor: owner)
      end
    end
    assert CoachPersonaEvaluationCase.find(evaluation_case.id).active?
    connection.execute("SET lock_timeout = DEFAULT")

    release_publish << true
    publisher.join
    version_id = publish_result.pop
    assert_kind_of Integer, version_id
    version = CoachPersonaVersion.find(version_id)
    assert version.release_evidence_valid?

    CoachPersona.find(persona.id).with_lock do
      CoachPersonaEvaluationCase.find(evaluation_case.id).retire!(actor: owner)
    end
    refute CoachPersonaEvaluationCase.find(evaluation_case.id).active?
    assert version.reload.release_evidence_valid?
  ensure
    connection&.execute("SET lock_timeout = DEFAULT")
    Mia::PersonaRelease::Evidence.define_method(:verify_current!, original_verify) if defined?(original_verify) && original_verify
    release_publish << true if defined?(release_publish) && release_publish&.empty?
    publisher&.join(2)
    cleanup_records
  end

  private

  def remember(owner, editor, reviewer, workspace, persona)
    @record_ids = {
      users: [ owner, editor, reviewer ].compact.map(&:id), workspace: workspace.id, persona: persona.id
    }
  end

  def cleanup_records
    return unless @record_ids

    candidate_ids = CoachPersonaReleaseCandidate.where(coach_persona_id: @record_ids[:persona]).pluck(:id)
    run_ids = CoachPersonaEvaluationRun.where(coach_persona_release_candidate_id: candidate_ids).pluck(:id)
    CoachPersonaPublicationEvent.where(coach_persona_id: @record_ids[:persona]).delete_all
    CoachPersona.where(id: @record_ids[:persona]).update_all(current_published_version_id: nil)
    version_ids = CoachPersonaVersion.where(coach_persona_id: @record_ids[:persona]).pluck(:id)
    CoachPersonaVersionPhraseArtifact.where(coach_persona_version_id: version_ids).delete_all
    CoachPersonaVersionContentPack.where(coach_persona_version_id: version_ids).delete_all
    CoachPersonaVersion.where(id: version_ids).delete_all
    CoachPersonaEvaluationApproval.where(coach_persona_evaluation_run_id: run_ids).delete_all
    CoachPersonaEvaluationResult.where(coach_persona_evaluation_run_id: run_ids).delete_all
    CoachPersonaEvaluationRun.where(id: run_ids).delete_all
    CoachPhraseAudienceAttestation.where(coach_persona_release_candidate_id: candidate_ids).delete_all
    CoachPersonaBehavioralPreviewEvidence.where(coach_persona_release_candidate_id: candidate_ids).delete_all
    CoachPersonaReleaseCandidate.where(id: candidate_ids).delete_all
    CoachPersonaEvaluationCase.where(coach_persona_id: @record_ids[:persona]).delete_all
    CoachPersona.where(id: @record_ids[:persona]).delete_all
    CoachProfile.where(coach_workspace_id: @record_ids[:workspace]).delete_all
    CoachWorkspaceMembership.where(coach_workspace_id: @record_ids[:workspace]).delete_all
    CoachWorkspace.where(id: @record_ids[:workspace]).delete_all
    User.where(id: @record_ids[:users]).delete_all
  end
end
