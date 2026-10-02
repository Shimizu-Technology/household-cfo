# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"

module Mia
  module PersonaRelease
    class Runner
      class Error < StandardError; end
      MAX_CASES = 24
      RUN_LEASE_TIMEOUT = 2.minutes
      EnqueueResult = Data.define(:run, :replayed)

      class << self
        def execute_pending!(run_id, adapter: HybridBehavioralAdapter.new)
          run = CoachPersonaEvaluationRun.find(run_id)
          cases = claim!(run)
          return run unless cases

          new(persona: run.release_candidate.coach_persona, actor: run.requested_by_user, adapter: adapter)
            .send(:execute!, run, cases)
        end

        private

        def claim!(run)
          run.with_lock do
            return if run.terminal?
            if run.status == "running"
              return complete_error!(run) if run.updated_at < RUN_LEASE_TIMEOUT.ago

              return
            end

            persona = run.release_candidate.coach_persona
            return complete_error!(run) unless persona.coach_workspace&.allows?(run.requested_by_user, :edit)
            return complete_error!(run) unless run.release_candidate.current_for?(persona)

            cases = persona.evaluation_cases.where(active: true).order(required: :desc, id: :asc).to_a
            return complete_error!(run) unless cases.length <= MAX_CASES && secure_match?(run.cases_digest, digest_cases(cases))

            run.update!(status: "running", started_at: Time.current, execution_attempts: run.execution_attempts + 1)
            cases
          end
        end

        def complete_error!(run)
          run.assign_attributes(status: "error", started_at: run.started_at || Time.current, completed_at: Time.current)
          run.run_digest = CoachPersonaEvaluationRun.digest_for(run: run, results: run.results.to_a)
          run.save!
          nil
        end

        def digest_cases(cases)
          Digest::SHA256.hexdigest(JSON.generate(cases.sort_by(&:id).map(&:case_digest)).b)
        end

        def secure_match?(left, right)
          left.to_s.bytesize == right.to_s.bytesize && ActiveSupport::SecurityUtils.secure_compare(left.to_s, right.to_s)
        end
      end

      def initialize(persona:, actor:, adapter: HybridBehavioralAdapter.new)
        @persona = persona
        @actor = actor
        @adapter = adapter
      end

      def enqueue!(request_key:)
        run, replayed = prepare_run!(request_key: request_key)
        enqueue_job!(run) unless run.terminal?
        EnqueueResult.new(run: run.reload, replayed: replayed)
      end

      # HTTP callers use enqueue!. This synchronous entry point supports deterministic service checks.
      def call!(request_key: "service:#{SecureRandom.uuid}")
        run, = prepare_run!(request_key: request_key)
        self.class.execute_pending!(run.id, adapter: adapter)
      end

      private

      attr_reader :persona, :actor, :adapter

      def prepare_run!(request_key:)
        authorize!
        key = RequestIdentity.normalize!(request_key)
        candidate = nil
        fingerprint = nil
        persona.with_lock do
          raise Error, "Archived personas cannot be evaluated" if persona.archived?

          candidate = CandidateBuilder.new(persona: persona, actor: actor).call!
          sealed_cases = evaluation_cases
          raise Error, "A persona evaluation can run at most #{MAX_CASES} cases" if sealed_cases.length > MAX_CASES

          fingerprint = request_fingerprint(key, candidate, sealed_cases)
          existing = CoachPersonaEvaluationRun.find_by(request_key: key)
          return [ reconcile!(existing, candidate, fingerprint), true ] if existing

          created_run = CoachPersonaEvaluationRun.create!(
            release_candidate: candidate,
            requested_by_user: actor,
            status: "pending",
            adapter_kind: adapter.kind,
            cases_digest: cases_digest(sealed_cases),
            request_key: key,
            request_fingerprint: fingerprint
          )
          [ created_run, false ]
        end
      rescue ActiveRecord::RecordNotUnique
        existing = CoachPersonaEvaluationRun.find_by!(request_key: key)
        [ reconcile!(existing, candidate, fingerprint), true ]
      rescue CandidateBuilder::Error, ActiveRecord::RecordInvalid, ArgumentError => error
        raise Error, error.message
      end

      def reconcile!(existing, candidate, fingerprint)
        same = existing.release_candidate.coach_persona_id == persona.id &&
          existing.requested_by_user_id == actor.id && secure_match?(existing.request_fingerprint, fingerprint) &&
          existing.coach_persona_release_candidate_id == candidate.id
        raise Error, "request_id was already used for a different evaluation" unless same

        existing
      end

      def enqueue_job!(run)
        run.update!(enqueued_at: Time.current) if run.enqueued_at.nil?
        PersonaEvaluationRunJob.perform_later(run.id)
      rescue ActiveJob::EnqueueError
        raise Error, "The evaluation could not be queued. Retry with the same request_id."
      end

      def authorize!
        raise Error, "Only a workspace editor can run persona evaluations" unless persona.coach_workspace&.allows?(actor, :edit)
      end

      def evaluation_cases
        SystemCases.ensure!(persona: persona, actor: actor)
        persona.evaluation_cases.where(active: true).order(required: :desc, id: :asc).to_a
      end

      def cases_digest(cases)
        self.class.send(:digest_cases, cases)
      end

      def request_fingerprint(key, candidate, cases)
        RequestIdentity.fingerprint(
          schema: "persona_evaluation_request_v1",
          request_key: key,
          persona_id: persona.id,
          actor_id: actor.id,
          candidate_digest: candidate.manifest_digest,
          cases_digest: cases_digest(cases),
          adapter_kind: adapter.kind
        )
      end

      def execute!(run, cases)
        ApplicationRecord.transaction do
          cases.each { |evaluation_case| execute_case!(run, evaluation_case) }
          terminal_status = run.results.reload.all? { |result| result.status == "passed" && !result.fallback_only? } ? "passed" : "failed"
          run.assign_attributes(status: terminal_status, completed_at: Time.current)
          run.run_digest = CoachPersonaEvaluationRun.digest_for(run: run, results: run.results.to_a)
          run.save!
        end
        run
      rescue StandardError => error
        if run.persisted? && !run.reload.terminal?
          run.assign_attributes(status: "error", started_at: run.started_at || Time.current, completed_at: Time.current)
          run.run_digest = CoachPersonaEvaluationRun.digest_for(run: run, results: run.results.to_a)
          run.save!
        end
        raise Error, "The persona evaluation could not complete: #{error.message}"
      end

      def execute_case!(run, evaluation_case)
        response = adapter.call(evaluation_case: evaluation_case, persona: persona, candidate: run.release_candidate)
        raise Error, "The behavioral adapter returned an invalid response" unless response.is_a?(BehavioralAdapter::Response)

        assertion_results = AssertionEvaluator.evaluate(
          evaluation_case.assertions,
          output: response.output,
          fallback_only: response.fallback_only,
          phrase_artifacts: run.release_candidate.config_snapshot["phrases"]
        )
        status = !response.fallback_only && assertion_results.all? { |assertion| assertion.fetch("passed") } ? "passed" : "failed"
        result = run.results.new(
          evaluation_case: evaluation_case,
          status: status,
          case_snapshot: evaluation_case.snapshot,
          output: response.output.to_s.first(LiveBehavioralAdapter::MAX_OUTPUT_CHARS),
          adapter_metadata: response.metadata,
          assertion_results: assertion_results,
          fallback_only: response.fallback_only
        )
        result.result_digest = CoachPersonaEvaluationResult.digest_for(result)
        result.save!
      end

      def secure_match?(left, right)
        left.to_s.bytesize == right.to_s.bytesize && ActiveSupport::SecurityUtils.secure_compare(left.to_s, right.to_s)
      end
    end
  end
end
