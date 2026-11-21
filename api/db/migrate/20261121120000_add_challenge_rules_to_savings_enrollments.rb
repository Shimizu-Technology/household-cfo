# frozen_string_literal: true

# A group's challenge length, check-in days, suggested goal and what counts toward the
# goal are now program settings. Each enrollment records the rules it started with, so a
# later program change never moves a running challenge's dates or what already counted.
# Every existing enrollment started under today's fixed rules, which the defaults backfill.
class AddChallengeRulesToSavingsEnrollments < ActiveRecord::Migration[8.0]
  IDENTITY_GUARD = "savings_identity_guard()"
  SCOPE_GUARD = "savings_scope_guard()"
  IDENTITY_FROM = [ "NEW.late_start_accepted,NEW.staff_preview)\n", "OLD.late_start_accepted,OLD.staff_preview) THEN RAISE EXCEPTION 'savings enrollment identity is frozen'" ].freeze
  IDENTITY_TO = [
    "NEW.late_start_accepted,NEW.staff_preview,NEW.challenge_length_days,NEW.checkpoint_days,NEW.suggested_goal_cents,NEW.goal_counts)\n",
    "OLD.late_start_accepted,OLD.staff_preview,OLD.challenge_length_days,OLD.checkpoint_days,OLD.suggested_goal_cents,OLD.goal_counts) THEN RAISE EXCEPTION 'savings enrollment identity is frozen'"
  ].freeze
  # A zero report conflicts with anything that counts toward this enrollment's goal.
  SCOPE_FROM = [ "AND v.funding_source IN ('earned_income','gift','bonus','new_money_reserved','withdrawal')\n" ].freeze
  SCOPE_TO = [ "AND (v.funding_source IN ('earned_income','gift','bonus','new_money_reserved','withdrawal') OR (v.funding_source = 'extra_debt_payment' AND enrollment.goal_counts = 'savings_and_debt'))\n" ].freeze
  # One to six check-in days, a plain one-dimensional array with no NULLs, strictly
  # increasing from day 1 or later and ending on the last day. A CHECK cannot use a
  # subquery, so each neighbouring pair is compared directly (at most six days).
  INCREASING = (2..6).map { |index| "(cardinality(checkpoint_days) < #{index} OR checkpoint_days[#{index}] > checkpoint_days[#{index - 1}])" }.join(" AND ")
  RULES_CHECK = "challenge_length_days BETWEEN 30 AND 180 AND cardinality(checkpoint_days) BETWEEN 1 AND 6 " \
    "AND array_ndims(checkpoint_days) = 1 AND array_lower(checkpoint_days, 1) = 1 AND array_position(checkpoint_days, NULL) IS NULL " \
    "AND checkpoint_days[1] >= 1 AND #{INCREASING} AND checkpoint_days[cardinality(checkpoint_days)] = challenge_length_days " \
    "AND suggested_goal_cents BETWEEN 10000 AND 500000 AND goal_counts IN ('savings','savings_and_debt')"
  OLD_SOURCES = "'earned_income','gift','bonus','new_money_reserved','preexisting','borrowed','cash_advance','existing_internal_money'"
  NEW_SOURCES = "#{OLD_SOURCES},'extra_debt_payment'"

  def up
    add_column :savings_enrollments, :challenge_length_days, :integer, null: false, default: 90
    add_column :savings_enrollments, :checkpoint_days, :integer, array: true, null: false, default: [ 30, 60, 90 ]
    add_column :savings_enrollments, :suggested_goal_cents, :integer, null: false, default: 50_000
    add_column :savings_enrollments, :goal_counts, :string, null: false, default: "savings"

    remove_check_constraint :savings_enrollments, name: "savings_enrollment_calendar_valid"
    add_check_constraint :savings_enrollments, "ends_on = (starts_on + challenge_length_days - 1) AND time_zone = 'Pacific/Guam' AND starts_on >= accepted_local_on",
      name: "savings_enrollment_calendar_valid"
    add_check_constraint :savings_enrollments, RULES_CHECK, name: "savings_enrollment_rules_valid"

    remove_check_constraint :savings_checkpoints, name: "savings_checkpoint_day_valid"
    add_check_constraint :savings_checkpoints, "milestone_day BETWEEN 1 AND 180", name: "savings_checkpoint_day_valid"
    remove_check_constraint :challenge_sponsor_exports, name: "challenge_sponsor_day"
    add_check_constraint :challenge_sponsor_exports, "checkpoint_day BETWEEN 1 AND 180", name: "challenge_sponsor_day"

    replace_entry_sources(OLD_SOURCES, NEW_SOURCES)
    replace_guard(IDENTITY_GUARD, IDENTITY_FROM, IDENTITY_TO)
    replace_guard(SCOPE_GUARD, SCOPE_FROM, SCOPE_TO)
  end

  # What the fixed 90-day schema could not hold, in plain words, for a refused rollback.
  ROLLBACK_BLOCKERS = {
    "an enrollment uses a challenge length, check-in days, suggested goal or counting rule other than 90 days, Day 30, 60 and 90, $500 and new money only" =>
      "SELECT 1 FROM savings_enrollments WHERE challenge_length_days <> 90 OR checkpoint_days <> '{30,60,90}' OR suggested_goal_cents <> 50000 OR goal_counts <> 'savings' LIMIT 1",
    "a check-in record is on a day other than 30, 60 or 90" => "SELECT 1 FROM savings_checkpoints WHERE milestone_day NOT IN (30, 60, 90) LIMIT 1",
    "a saved sponsor report is for a day other than 30, 60 or 90" => "SELECT 1 FROM challenge_sponsor_exports WHERE checkpoint_day NOT IN (30, 60, 90) LIMIT 1",
    "a saved savings entry is an extra debt payment" => "SELECT 1 FROM savings_entry_versions WHERE funding_source = 'extra_debt_payment' LIMIT 1",
    "a savings entry waiting for review is an extra debt payment" => "SELECT 1 FROM savings_entry_drafts WHERE funding_source = 'extra_debt_payment' LIMIT 1"
  }.freeze

  def down
    blockers = ROLLBACK_BLOCKERS.filter_map { |reason, sql| reason if select_value(sql) }
    if blockers.any?
      raise ActiveRecord::IrreversibleMigration, "This rollback was stopped because the fixed 90-day schema cannot hold what is already saved: #{blockers.join('; ')}. Nothing was changed."
    end

    replace_guard(SCOPE_GUARD, SCOPE_TO, SCOPE_FROM)
    replace_guard(IDENTITY_GUARD, IDENTITY_TO, IDENTITY_FROM)
    replace_entry_sources(NEW_SOURCES, OLD_SOURCES)

    remove_check_constraint :challenge_sponsor_exports, name: "challenge_sponsor_day"
    add_check_constraint :challenge_sponsor_exports, "checkpoint_day IN (30, 60, 90)", name: "challenge_sponsor_day"
    remove_check_constraint :savings_checkpoints, name: "savings_checkpoint_day_valid"
    add_check_constraint :savings_checkpoints, "milestone_day IN (30, 60, 90)", name: "savings_checkpoint_day_valid"

    remove_check_constraint :savings_enrollments, name: "savings_enrollment_rules_valid"
    remove_check_constraint :savings_enrollments, name: "savings_enrollment_calendar_valid"
    add_check_constraint :savings_enrollments, "ends_on = starts_on + 89 AND time_zone = 'Pacific/Guam' AND starts_on >= accepted_local_on",
      name: "savings_enrollment_calendar_valid"
    remove_column :savings_enrollments, :goal_counts
    remove_column :savings_enrollments, :suggested_goal_cents
    remove_column :savings_enrollments, :checkpoint_days
    remove_column :savings_enrollments, :challenge_length_days
  end

  private

  def replace_entry_sources(_from, to)
    remove_check_constraint :savings_entry_versions, name: "savings_entry_version_values_valid"
    add_check_constraint :savings_entry_versions, "currency = 'USD' AND evidence_supported_cents = 0 AND version_number > 0 AND approval_sequence > 0 AND " \
      "((funding_source = 'withdrawal' AND signed_cents <= 0) OR (funding_source IN (#{to}) AND signed_cents >= 0))", name: "savings_entry_version_values_valid"
  end

  def replace_guard(signature, from, to)
    definition = select_value("SELECT pg_get_functiondef(to_regprocedure('#{signature}'))")
    raise "#{signature} is missing" if definition.blank?
    raise "#{signature} no longer has the expected checks" unless from.all? { |text| definition.include?(text) }

    from.zip(to).each { |old_text, new_text| definition = definition.sub(old_text, new_text) }
    execute definition
  end
end
