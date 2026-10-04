# frozen_string_literal: true

module CohortReleases
  # Published catalogs are literal evidence, never a projection of today's registry.
  # Extend with another version; do not edit a catalog already used by a release.
  module ToolContracts
    def self.deep_freeze(value)
      case value
      when Hash then value.each { |key, entry| deep_freeze(key); deep_freeze(entry) }
      when Array then value.each { |entry| deep_freeze(entry) }
      end
      value.freeze
    end

    V1 = deep_freeze(
      {
        "schema_version" => 1,
        "modules" => [
          { "id" => "home", "label" => "Home", "core" => true },
          { "id" => "review", "label" => "Review", "core" => true },
          { "id" => "ask_mia", "label" => "Ask Mia", "core" => true },
          { "id" => "budget", "label" => "Budget", "core" => true },
          { "id" => "profile", "label" => "My Profile", "core" => true },
          { "id" => "wealth", "label" => "Wealth", "core" => true },
          { "id" => "cfo_filter", "label" => "CFO Filter", "core" => false,
            "unavailable_message" => "CFO Filter is not included in this cohort right now. You can still ask Mia about this decision." },
          { "id" => "optionality", "label" => "Optionality", "core" => false,
            "unavailable_message" => "Optionality is not included in this cohort right now. You can still ask Mia about your choices." }
        ],
        "operations" => %w[
          account.plaid.link account.plaid.reconcile account.plaid.unlink
          account.record.archive account.record.create account.record.restore account.record.update
          budget.allocation.set budget.category.archive budget.category.create budget.category.restore budget.category.update
          debt.record.archive debt.record.create debt.record.restore debt.record.update debt.tracking_mode.update
          goal.record.archive goal.record.create goal.record.restore goal.record.update goal.runway_policy.update goal.transition_policy.update
          income.schedule.create income.schedule.delete income.schedule.update
          income.source.archive income.source.create income.source.restore income.source.update
          profile.household.update profile.setup_confirmation.update
          transaction.draft.confirm transaction.draft.create transaction.draft.ignore transaction.draft.match
          transaction.draft.reopen transaction.draft.update transaction.drafts.bulk_confirm transaction.drafts.bulk_ignore
        ].map { |key| { "key" => key, "version" => 1 } }
      }
    )
    V2 = deep_freeze(V1.merge("schema_version" => 2, "experience_schema_versions" => [ 1, 2 ]))
    V3 = deep_freeze(V2.merge(
      "schema_version" => 3, "experience_schema_versions" => [ 1, 2, 3 ],
      "operations" => V1.fetch("operations") + %w[
        savings.enrollment.accept savings.plan.stage savings.plan.approve
        savings.entry.stage savings.entry.approve savings.zero.attest
        source_review.account.link source_review.draft.stage source_review.draft.approve
        source_review.draft.cancel source_review.revision.approve source_review.economic.link
        source_review.expense.project
      ].map { |key| { "key" => key, "version" => 1 } }
    ))
    V4 = deep_freeze(V3.merge(
      "schema_version" => 4,
      "operations" => V3.fetch("operations") + %w[
        baseline.approve baseline.revise
        savings.daily.purchase.stage savings.daily.purchase.approve
        savings.daily.reflection.save savings.daily.reflection.erase savings.daily.check_in.save
        savings.checkpoint.stage savings.checkpoint.approve savings.daily.category.create
        privacy.consent.set support.request.create support.access.grant support.access.revoke
        source_use.authorize source_use.revoke reminder.preference.set reminder.dismiss
        savings.evidence.attach savings.evidence.revoke
      ].map { |key| { "key" => key, "version" => 1 } }
    ))
    V5 = deep_freeze(V4.merge(
      "schema_version" => 5,
      "operations" => V4.fetch("operations") + %w[
        savings.debt.stage savings.debt.approve
      ].map { |key| { "key" => key, "version" => 1 } }
    ))
    SUPPORTED = { 1 => V1, 2 => V2, 3 => V3, 4 => V4, 5 => V5 }.freeze
    EXPERIENCE_CONTRACT_VERSIONS = { 1 => 1, 2 => 2, 3 => 5 }.freeze

    module_function

    def fetch(version)
      SUPPORTED.fetch(version)
    end

    def version_for_experience(config)
      EXPERIENCE_CONTRACT_VERSIONS.fetch(config.fetch("schema_version"))
    end

    def supported_snapshot?(snapshot, version:)
      SUPPORTED[version] == snapshot && SUPPORTED.key?(version)
    end

    def supports_experience?(snapshot, config)
      return false if CohortExperience::Schema.errors(config).any?

      versions = snapshot.fetch("experience_schema_versions", [ 1 ])
      versions.include?(config.fetch("schema_version"))
    end

    def runtime_compatible?(snapshot, version:, runtime_snapshot:)
      return false unless supported_snapshot?(snapshot, version: version)
      return false unless runtime_snapshot.is_a?(Hash) && SUPPORTED.key?(runtime_snapshot["schema_version"])

      modules = indexed_entries(runtime_snapshot["modules"], "id")
      operations = indexed_entries(runtime_snapshot["operations"], "key")
      return false unless modules && operations

      snapshot.fetch("modules").all? { |entry| modules[entry.fetch("id")] == entry } &&
        snapshot.fetch("operations").all? { |entry| operations[entry.fetch("key")] == entry }
    end

    def indexed_entries(entries, key)
      return unless entries.is_a?(Array)
      return unless entries.all? { |entry| entry.is_a?(Hash) && entry[key].is_a?(String) }
      return unless entries.map { |entry| entry.fetch(key) }.uniq.length == entries.length

      entries.index_by { |entry| entry.fetch(key) }
    end
  end
end
