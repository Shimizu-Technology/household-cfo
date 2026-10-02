# frozen_string_literal: true

namespace :cohort_releases do
  desc "Seal immutable shadow releases for existing cohorts without changing participant runtime"
  task reconcile_legacy: :environment do
    counts = CohortReleases::LegacyReconciler.new.call
    puts JSON.generate(counts.sort.to_h)
    abort "Cohort release reconciliation completed with errors" if counts[:errors].to_i.positive?
  end
end
