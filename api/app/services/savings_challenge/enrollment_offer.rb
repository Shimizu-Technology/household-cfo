module SavingsChallenge
  class EnrollmentOffer
    def self.call(cohort:, user:, membership:, at: Time.current)
      local = at.in_time_zone(SavingsEnrollment::TIME_ZONE).to_date
      configured = cohort.starts_on
      start = configured && [ configured, local ].max
      runtime = AccessPolicy.runtime_for(user: user, membership: membership)
      raise AccessPolicy::Unavailable, "The challenge release is unavailable" unless runtime

      # The rules she would join with come from her live release; the digest covers them.
      rules = Rules.for_runtime(runtime)
      offer = {
        policy_version: cohort.savings_challenge_policy_version, time_zone: SavingsEnrollment::TIME_ZONE,
        cohort_label: cohort.name, local_today: local, configured_starts_on: configured,
        configured_ends_on: cohort.ends_on, personal_starts_on: start, personal_ends_on: start && rules.last_day(start),
        late_start_acceptance_required: configured && local > configured,
        accepting_enrollments: configured.present? && cohort.status.in?(%w[enrolling active]),
        cohort_release_id: runtime.release_id, **rules.payload
      }
      offer.merge(acceptance_digest: CohortReleases::Contract.digest(
        offer.merge(cohort_id: cohort.id, membership_id: membership.id, membership_started_at: membership.created_at,
          release_digest: runtime.release.bundle_digest, capacity: cohort.savings_challenge_capacity)
      ))
    end
  end
end
