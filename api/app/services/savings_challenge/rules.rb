module SavingsChallenge
  # A savings challenge's rules: how many days it runs, the check-in days, the goal Mia
  # suggests and whether extra debt payments count toward the goal. They are program
  # settings (the `challenge` key of the method block). An enrollment records the rules
  # it started with, so a later program change never moves a running challenge's dates
  # or what already counted; a new enrollment reads the group's live release.
  Rules = Data.define(:length_days, :checkpoint_days, :suggested_goal_cents, :counts) do
    def self.from_setting(challenge)
      challenge = challenge.to_h.stringify_keys
      new(length_days: challenge.fetch("length_days"), checkpoint_days: CohortExperience::MethodSettings.checkpoint_days(challenge).freeze,
        suggested_goal_cents: challenge.fetch("suggested_goal_cents"), counts: challenge.fetch("counts"))
    end

    def self.default
      from_setting(CohortExperience::MethodSettings::CHALLENGE_DEFAULTS)
    end

    # The rules a participant's runtime offers (her experience capabilities).
    def self.for_capabilities(capabilities)
      from_setting(CohortExperience::MethodSettings.from_capabilities(capabilities).fetch("challenge"))
    end

    def self.for_runtime(runtime)
      for_capabilities(runtime.capabilities)
    end

    # The rules a group's live release gives a new enrollment. Never raises; a group
    # without a usable release reads as the defaults.
    def self.for_cohort(cohort)
      for_release(cohort&.active_cohort_release)
    end

    # The rules a sealed release's experience carries (no further queries).
    def self.for_release(release)
      return default unless release

      from_setting(CohortExperience::Schema.method_for(release.experience_snapshot.to_h.fetch("config", {})).fetch("challenge"))
    rescue StandardError => error
      Rails.logger.error("[SavingsChallenge::Rules] default rules cohort_release_id=#{release&.id} error=#{error.class}")
      default
    end

    # The rules an enrollment started with.
    def self.for_enrollment(enrollment)
      new(length_days: enrollment.challenge_length_days, checkpoint_days: Array(enrollment.checkpoint_days).freeze,
        suggested_goal_cents: enrollment.suggested_goal_cents, counts: enrollment.goal_counts)
    end

    # The rules an offer carries, or the group's when the person has no offer yet.
    def self.for_offer(offer)
      new(length_days: offer.fetch(:challenge_length_days), checkpoint_days: offer.fetch(:checkpoint_days).freeze,
        suggested_goal_cents: offer.fetch(:suggested_goal_cents), counts: offer.fetch(:goal_counts))
    end

    def counts_debt?
      counts == "savings_and_debt"
    end

    def final_day
      checkpoint_days.last
    end

    def last_day(starts_on)
      starts_on + length_days - 1
    end

    def checkpoint?(day)
      checkpoint_days.include?(day)
    end

    def checkpoint_dates(starts_on)
      checkpoint_days.to_h { |day| [ day, starts_on + day - 1 ] }
    end

    def enrollment_attributes
      { challenge_length_days: length_days, checkpoint_days: checkpoint_days.dup, suggested_goal_cents: suggested_goal_cents, goal_counts: counts }
    end

    # Offer and participant payload. Plain values only; the offer digest covers them.
    def payload
      { challenge_length_days: length_days, checkpoint_days: checkpoint_days.dup, suggested_goal_cents: suggested_goal_cents, goal_counts: counts }
    end

    # "Day 30, 60 and 90" / "Day 60" — the check-in days in a sentence.
    def checkpoint_text
      days = checkpoint_days.map(&:to_s)
      "Day #{days.length == 1 ? days.first : "#{days[0..-2].join(', ')} and #{days.last}"}"
    end

    # "Day 30, 60 or 90", for a choice between them.
    def checkpoint_choice_text
      days = checkpoint_days.map(&:to_s)
      "Day #{days.length == 1 ? days.first : "#{days[0..-2].join(', ')} or #{days.last}"}"
    end

    def label
      "#{length_days}-day"
    end

    # What counts toward the goal, in a participant's words.
    def counts_text
      if counts_debt?
        "New money you set aside counts toward the goal, and so do extra payments on a card or loan beyond the minimum."
      else
        "Only new money you actually set aside counts toward the goal. Extra debt payments are tracked alongside but don't count."
      end
    end

    # A weekly pace over the whole challenge, to the nearest cent.
    def weekly_total(weekly_cents)
      (weekly_cents * length_days + 3) / 7
    end
  end
end
