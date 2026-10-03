# frozen_string_literal: true

module CohortReleases
  class RuntimeActivator
    REQUEST_KEY = "runtime-activation-v1"
    RELEASE_KEY_PREFIX = "runtime-reconciliation-v1"

    Result = Data.define(:cohort_id, :release_id, :status, :sealed, :message)

    class Error < StandardError; end
    class OpenLegacyRollout < Error; end
    class Drift < Error; end

    def initialize(cohort:)
      @cohort = cohort
    end

    def call!
      cohort.with_lock do
        reject_pre_cutover_rollout!
        existing_event = cohort.cohort_release_activation_events.find_by(request_key: REQUEST_KEY)
        if existing_event
          release = verify_activation_chain!(existing_event)
          return Result.new(cohort_id: cohort.id, release_id: release.id, status: "replayed", sealed: false, message: nil)
        end
        candidate = CandidateBuilder.new(cohort: cohort, strict: false).call
        if cohort.active_cohort_release
          verify_parity!(candidate, cohort.active_cohort_release)
          return Result.new(
            cohort_id: cohort.id,
            release_id: cohort.active_cohort_release_id,
            status: "already_active",
            sealed: false,
            message: nil
          )
        end

        release, sealed = compatible_release(candidate)
        verify_parity!(candidate, release)
        occurred_at = Time.current
        fingerprint = activation_fingerprint(release)
        cohort.cohort_release_activation_events.create!(
          coach_workspace: cohort.coach_workspace,
          from_cohort_release: nil,
          to_cohort_release: release,
          event_type: "backfill",
          request_key: REQUEST_KEY,
          request_fingerprint: fingerprint,
          occurred_at: occurred_at
        )
        cohort.update!(active_cohort_release: release)
        Result.new(cohort_id: cohort.id, release_id: release.id, status: "activated", sealed: sealed, message: nil)
      end
    end

    def self.call(scope: Cohort.all, batch_size: 100)
      results = []
      scope.find_each(batch_size: batch_size) do |cohort|
        results << new(cohort: cohort).call!
      rescue StandardError => error
        Rails.logger.error("[CohortReleases::RuntimeActivator] cohort_id=#{cohort.id} error=#{error.class}")
        results << Result.new(
          cohort_id: cohort.id,
          release_id: nil,
          status: "error",
          sealed: false,
          message: error.message
        )
      end
      results
    end

    private

    attr_reader :cohort

    def reject_pre_cutover_rollout!
      return unless cohort.cohort_rollouts.where(status: CohortRollout::OPEN_STATUSES, baseline_cohort_release_id: nil).exists?

      raise OpenLegacyRollout, "Cancel or finish the pre-cutover rollout before activating release runtime."
    end

    def compatible_release(candidate)
      existing = cohort.cohort_releases.order(release_number: :desc).find do |release|
        report = release.integrity_report
        report.fetch(:valid) && report.fetch(:runtime_compatible) &&
          SemanticParity.new(candidate: candidate, release: release).equivalent?
      end
      return [ existing, false ] if existing

      key = "#{RELEASE_KEY_PREFIX}:#{candidate.bundle_digest.first(24)}"
      release = Sealer.new(cohort: cohort, actor: nil, publication_source: "system").call!(
        request_key: key,
        event_type: "reconciliation"
      )
      [ release, true ]
    end

    def verify_parity!(candidate, release)
      report = release.integrity_report
      parity = SemanticParity.new(candidate: candidate, release: release).equivalent?
      return if parity && report.fetch(:valid) && report.fetch(:runtime_compatible)

      raise Drift, "The activation release does not reproduce the legacy participant runtime bundle."
    end

    def verify_activation_chain!(origin)
      release = origin.to_cohort_release
      verify_release_integrity!(release)
      cohort.cohort_release_activation_events.where("id > ?", origin.id).order(:id).each do |event|
        unless event.from_cohort_release_id == release.id
          raise Drift, "Runtime activation evidence does not form one contiguous release chain."
        end
        release = event.to_cohort_release
        verify_release_integrity!(release)
      end
      unless cohort.active_cohort_release_id == release.id
        raise Drift, "Existing runtime activation evidence does not match the active release."
      end

      release
    end

    def verify_release_integrity!(release)
      report = release.integrity_report
      return if report.fetch(:valid) && report.fetch(:runtime_compatible)

      raise Drift, "The active runtime release failed immutable integrity or compatibility checks."
    end

    def activation_fingerprint(release)
      Contract.digest(
        "schema" => "cohort_release_activation_v1",
        "cohort_id" => cohort.id,
        "from_release_id" => nil,
        "to_release_id" => release.id,
        "request_key" => REQUEST_KEY,
        "bundle_digest" => release.bundle_digest
      )
    end
  end
end
