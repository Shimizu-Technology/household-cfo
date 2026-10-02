# frozen_string_literal: true

module CohortReleases
  class LegacyReconciler
    REQUEST_KEY = CohortRelease::LEGACY_RECONCILIATION_REQUEST_KEY

    def initialize(scope: Cohort.all)
      @scope = scope
    end

    def call(batch_size: 100)
      counts = Hash.new(0)
      scope.find_each(batch_size: batch_size) do |cohort|
        candidate = CandidateBuilder.new(cohort: cohort, strict: false).call
        existing = cohort.cohort_releases.find_by(request_key: REQUEST_KEY)
        if existing && (existing.publication_source != "legacy_backfill" || existing.event_type != "reconciliation")
          raise "Reserved legacy request key belongs to non-reconciliation release evidence"
        end
        release = existing || Sealer.new(
          cohort: cohort,
          actor: nil,
          publication_source: "legacy_backfill"
        ).call!(request_key: REQUEST_KEY, event_type: "reconciliation")
        raise "Existing legacy release failed integrity validation" unless release.integrity_valid?

        counts[existing ? :replayed : :sealed] += 1
        counts[release.persona_mode.to_sym] += 1
        counts[release.experience_mode.to_sym] += 1
        if candidate.ambiguous_participant_count.positive?
          counts[:ambiguous_cohorts] += 1
          counts[:ambiguous_participants] += candidate.ambiguous_participant_count
        end
      rescue StandardError => error
        counts[:errors] += 1
        Rails.logger.error("[CohortReleases::LegacyReconciler] cohort_id=#{cohort.id} error=#{error.class}")
      end
      counts
    end

    private

    attr_reader :scope
  end
end
