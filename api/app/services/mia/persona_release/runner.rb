# frozen_string_literal: true

require "digest"
require "json"

module Mia
  module PersonaRelease
    class Runner
      class Error < StandardError; end
      MAX_CASES = 24

      def initialize(persona:, actor:, adapter: DeterministicAdapter.new)
        @persona = persona
        @actor = actor
        @adapter = adapter
      end

      def call!
        authorize!
        run, cases = persona.with_lock do
          raise Error, "Archived personas cannot be evaluated" if persona.archived?

          candidate = CandidateBuilder.new(persona: persona, actor: actor).call!
          sealed_cases = evaluation_cases
          raise Error, "A persona evaluation can run at most #{MAX_CASES} cases" if sealed_cases.length > MAX_CASES

          created_run = CoachPersonaEvaluationRun.create!(
            release_candidate: candidate,
            requested_by_user: actor,
            status: "pending",
            adapter_kind: adapter.kind,
            cases_digest: cases_digest(sealed_cases)
          )
          [ created_run, sealed_cases ]
        end
        execute!(run, cases)
      rescue CandidateBuilder::Error, ActiveRecord::RecordInvalid, ArgumentError => error
        raise Error, error.message
      end

      private

      attr_reader :persona, :actor, :adapter

      def authorize!
        raise Error, "Only a workspace editor can run persona evaluations" unless persona.coach_workspace&.allows?(actor, :edit)
      end

      def evaluation_cases
        SystemCases.ensure!(persona: persona, actor: actor)
        persona.evaluation_cases.where(active: true).order(required: :desc, id: :asc).to_a
      end

      def cases_digest(cases)
        Digest::SHA256.hexdigest(JSON.generate(cases.sort_by(&:id).map(&:case_digest)).b)
      end

      def execute!(run, cases)
        run.update!(status: "running", started_at: Time.current)
        ApplicationRecord.transaction do
          cases.each { |evaluation_case| execute_case!(run, evaluation_case) }
          terminal_status = run.results.reload.all? { |result| result.status == "passed" && !result.fallback_only? } ? "passed" : "failed"
          run.assign_attributes(status: terminal_status, completed_at: Time.current)
          run.run_digest = CoachPersonaEvaluationRun.digest_for(run: run, results: run.results.to_a)
          run.save!
        end
        run
      rescue StandardError => error
        if run.persisted? && !run.reload.status.in?(%w[passed failed error])
          run.assign_attributes(status: "error", completed_at: Time.current)
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
          phrase_artifacts: persona.draft_config["phrases"]
        )
        status = !response.fallback_only && assertion_results.all? { |assertion| assertion.fetch("passed") } ? "passed" : "failed"
        result = run.results.new(
          evaluation_case: evaluation_case,
          status: status,
          case_snapshot: evaluation_case.snapshot,
          output: response.output.to_s.first(20_000),
          adapter_metadata: response.metadata,
          assertion_results: assertion_results,
          fallback_only: response.fallback_only
        )
        result.result_digest = CoachPersonaEvaluationResult.digest_for(result)
        result.save!
      end
    end
  end
end
