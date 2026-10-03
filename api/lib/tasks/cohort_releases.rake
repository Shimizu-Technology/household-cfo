# frozen_string_literal: true

namespace :cohort_releases do
  desc "Seal immutable shadow releases for existing cohorts without changing participant runtime"
  task reconcile_legacy: :environment do
    counts = CohortReleases::LegacyReconciler.new.call
    puts JSON.generate(counts.sort.to_h)
    abort "Cohort release reconciliation completed with errors" if counts[:errors].to_i.positive?
  end
end

namespace :cohort_releases do
  desc "Activate the immutable release runtime for cohorts after verifying legacy parity"
  task activate_runtime: :environment do
    results = CohortReleases::RuntimeActivator.call
    payload = results.map(&:to_h)
    puts JSON.generate(payload)
    abort "Cohort runtime activation completed with errors" if results.any? { |result| result.status == "error" }
  end
end
