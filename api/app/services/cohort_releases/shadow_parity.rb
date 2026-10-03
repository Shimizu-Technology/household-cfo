# frozen_string_literal: true

module CohortReleases
  class ShadowParity
    def initialize(cohort)
      @cohort = cohort
    end

    def call
      release = cohort.cohort_releases.order(release_number: :desc).first
      return payload("unreconciled", release: nil) unless release

      report = release.integrity_report
      return payload("corrupt", release: release, integrity: report) unless report.fetch(:valid)

      candidate = CandidateBuilder.new(cohort: cohort, strict: false).call
      state = SemanticParity.new(candidate: candidate, release: release).equivalent? ? "in_sync" : "drifted"
      payload(state, release: release, integrity: report, candidate: candidate)
    rescue StandardError => error
      Rails.logger.error("[CohortReleases::ShadowParity] cohort_id=#{cohort.id} error=#{error.class}")
      payload("error", release: release)
    end

    private

    attr_reader :cohort

    def payload(state, release:, integrity: nil, candidate: nil)
      {
        state: state,
        cohort_id: cohort.id,
        release_id: release&.id,
        release_number: release&.release_number,
        publication_source: release&.publication_source,
        persona_mode: release&.persona_mode,
        experience_mode: release&.experience_mode,
        runtime_compatible: integrity&.fetch(:runtime_compatible, false),
        warning_count: candidate&.warnings&.length.to_i
      }
    end
  end
end
