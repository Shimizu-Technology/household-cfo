# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"

module Mia
  module PersonaRelease
    class Runner
      class Error < StandardError; end
      class LeaseLost < Error; end
      MAX_CASES = 24
      LEASE_DURATION = 90.seconds
      EnqueueResult = Data.define(:run, :replayed, :enqueued)

      class << self
        def execute_pending!(run_id, lease_token:, adapter: HybridBehavioralAdapter.new)
          run = CoachPersonaEvaluationRun.find(run_id)
          cases = claim!(run, lease_token)
          return run unless cases

          new(persona: run.release_candidate.coach_persona, actor: run.requested_by_user, adapter: adapter)
            .send(:execute!, run, cases, lease_token)
        end

        def reserve_lease!(run)
          run.with_lock do
            return [ nil, false ] if run.terminal?
            return [ run.lease_token, false ] if run.execution_lease_active?

            token = SecureRandom.uuid
            now = Time.current
            run.update!(lease_token: token, heartbeat_at: now, lease_expires_at: now + LEASE_DURATION,
              lease_claimed_at: nil, enqueued_at: run.enqueued_at || now)
            [ token, true ]
          end
        end

        private

        def claim!(run, token)
          run.with_lock do
            return if run.terminal? || !secure_match?(run.lease_token, token)
            return if run.lease_claimed_at.present? && run.execution_lease_active?

            persona = run.release_candidate.coach_persona
            return complete_error!(run, token) unless persona.coach_workspace&.allows?(run.requested_by_user, :edit)
            return complete_error!(run, token) unless run.release_candidate.current_for?(persona)

            cases = persona.evaluation_cases.where(active: true).order(required: :desc, id: :asc).to_a
            return complete_error!(run, token) unless cases.length <= MAX_CASES && secure_match?(run.cases_digest, digest_cases(cases))

            now = Time.current
            run.update!(status: "running", started_at: run.started_at || now, execution_attempts: run.execution_attempts + 1,
              heartbeat_at: now, lease_expires_at: now + LEASE_DURATION)
            run.update!(lease_claimed_at: now)
            cases
          end
        end

        def complete_error!(run, token)
          return unless secure_match?(run.lease_token, token)

          run.assign_attributes(status: "error", started_at: run.started_at || Time.current, completed_at: Time.current,
            lease_token: nil, heartbeat_at: nil, lease_expires_at: nil, lease_claimed_at: nil)
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
        token, should_enqueue = self.class.reserve_lease!(run)
        enqueue_job!(run, token) if should_enqueue
        EnqueueResult.new(run: run.reload, replayed: replayed, enqueued: should_enqueue)
      end

      def call!(request_key: "service:#{SecureRandom.uuid}")
        run, = prepare_run!(request_key: request_key)
        token, = self.class.reserve_lease!(run)
        self.class.execute_pending!(run.id, lease_token: token, adapter: adapter)
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
            release_candidate: candidate, requested_by_user: actor, status: "pending", adapter_kind: adapter.kind,
            cases_digest: cases_digest(sealed_cases), request_key: key, request_fingerprint: fingerprint
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

      def enqueue_job!(run, token)
        PersonaEvaluationRunJob.perform_later(run.id, token)
      rescue ActiveJob::EnqueueError
        run.with_lock do
          if secure_match?(run.lease_token, token) && run.status == "pending"
            run.update!(lease_token: nil, heartbeat_at: nil, lease_expires_at: nil, lease_claimed_at: nil)
          end
        end
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
        RequestIdentity.fingerprint(schema: "persona_evaluation_request_v1", request_key: key, persona_id: persona.id,
          actor_id: actor.id, candidate_digest: candidate.manifest_digest, cases_digest: cases_digest(cases), adapter_kind: adapter.kind)
      end

      def execute!(run, cases, token)
        cases.each do |evaluation_case|
          next if run.results.exists?(coach_persona_evaluation_case_id: evaluation_case.id)

          heartbeat!(run, token)
          execute_case!(run, evaluation_case, token)
        end
        complete!(run, cases, token)
      rescue LeaseLost
        run.reload
      rescue StandardError => error
        terminalize_error!(run, token)
        raise Error, "The persona evaluation could not complete: #{error.message}"
      end

      def execute_case!(run, evaluation_case, token)
        response = adapter.call(evaluation_case: evaluation_case, persona: persona, candidate: run.release_candidate)
        raise Error, "The behavioral adapter returned an invalid response" unless response.is_a?(BehavioralAdapter::Response)

        heartbeat!(run, token)
        assertion_results = AssertionEvaluator.evaluate(evaluation_case.assertions, output: response.output,
          fallback_only: response.fallback_only, phrase_artifacts: run.release_candidate.config_snapshot["phrases"])
        status = !response.fallback_only && assertion_results.all? { |assertion| assertion.fetch("passed") } ? "passed" : "failed"
        result = run.results.new(evaluation_case: evaluation_case, status: status, case_snapshot: evaluation_case.snapshot,
          output: response.output.to_s.first(LiveBehavioralAdapter::MAX_OUTPUT_CHARS), adapter_metadata: response.metadata,
          assertion_results: assertion_results, fallback_only: response.fallback_only)
        result.result_digest = CoachPersonaEvaluationResult.digest_for(result)
        result.save!
      end

      def heartbeat!(run, token)
        now = Time.current
        updated = CoachPersonaEvaluationRun.where(id: run.id, status: "running", lease_token: token)
          .update_all(heartbeat_at: now, lease_expires_at: now + LEASE_DURATION, updated_at: now)
        raise LeaseLost, "Evaluation lease was lost" unless updated == 1
      end

      def complete!(run, cases, token)
        run.with_lock do
          raise LeaseLost, "Evaluation lease was lost" unless secure_match?(run.lease_token, token)
          results = run.results.reload.to_a
          expected_ids = cases.map(&:id).sort
          raise Error, "Evaluation results are incomplete" unless results.map(&:coach_persona_evaluation_case_id).sort == expected_ids

          terminal_status = results.all? { |result| result.status == "passed" && !result.fallback_only? } ? "passed" : "failed"
          run.assign_attributes(status: terminal_status, completed_at: Time.current, lease_token: nil, heartbeat_at: nil,
            lease_expires_at: nil, lease_claimed_at: nil)
          run.run_digest = CoachPersonaEvaluationRun.digest_for(run: run, results: results)
          run.save!
        end
        run
      end

      def terminalize_error!(run, token)
        run.with_lock { self.class.send(:complete_error!, run, token) } if run.persisted? && !run.reload.terminal?
      rescue ActiveRecord::RecordInvalid
        nil
      end

      def secure_match?(left, right)
        left.to_s.bytesize == right.to_s.bytesize && ActiveSupport::SecurityUtils.secure_compare(left.to_s, right.to_s)
      end
    end
  end
end
