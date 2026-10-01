require_relative "base"

module HouseholdFinance
  module Operations
    module Debt
      class TrackingModeUpdate < Base
        KEY = "debt.tracking_mode.update"
        VERSION = 1

        private

        def normalize(input)
          mode = input[:mode].to_s
          raise ArgumentError, "Choose summary or individual debt tracking" unless mode.in?(HouseholdProfile::DEBT_TRACKING_MODES)
          values = { mode: mode }
          if mode == "summary"
            unless input.key?(:summary_balance) || input.key?(:summary_balance_cents)
              raise ArgumentError, "Enter the total debt balance, or leave it blank to mark it unknown"
            end
            unless input.key?(:summary_minimum_payment) || input.key?(:summary_minimum_payment_cents)
              raise ArgumentError, "Enter the total monthly minimum, or leave it blank to mark it unknown"
            end
            values.merge!(normalize_optional_money(input, :summary_balance, :summary_balance_cents, label: "Summary balance"))
            values.merge!(normalize_optional_money(input, :summary_minimum_payment, :summary_minimum_payment_cents, label: "Summary minimum payment"))
          end
          values
        end

        def subject_for(_input, lock:)
          profile = household.household_profile || household.create_household_profile!
          lock ? HouseholdProfile.lock.find(profile.id) : profile
        end

        def canonical_snapshot(profile, _input, lock:)
          debts = active_debt_snapshots(lock: lock)
          profile_values = profile_snapshot(profile).stringify_keys
          {
            profile: profile_values,
            active_debts: debts,
            portfolio: portfolio_snapshot(profile_values, debts)
          }
        end

        def predicted_after(before, input)
          profile = before.fetch("profile").merge("debt_tracking_mode" => input.fetch(:mode))
          profile["debt_summary_balance_cents"] = input.fetch(:summary_balance_cents) if input.key?(:summary_balance_cents)
          profile["debt_summary_balance_known"] = input.fetch(:summary_balance_known) if input.key?(:summary_balance_known)
          profile["debt_summary_minimum_payment_cents"] = input.fetch(:summary_minimum_payment_cents) if input.key?(:summary_minimum_payment_cents)
          profile["debt_summary_minimum_payment_known"] = input.fetch(:summary_minimum_payment_known) if input.key?(:summary_minimum_payment_known)
          debts = before.fetch("active_debts")
          {
            profile: profile,
            active_debts: debts,
            portfolio: portfolio_snapshot(profile, debts)
          }
        end

        def mutate!(profile, input, prepared:)
          attributes = { debt_tracking_mode: input.fetch(:mode) }
          attributes[:debt_summary_balance_cents] = input.fetch(:summary_balance_cents) if input.key?(:summary_balance_cents)
          attributes[:debt_summary_balance_known] = input.fetch(:summary_balance_known) if input.key?(:summary_balance_known)
          attributes[:debt_summary_minimum_payment_cents] = input.fetch(:summary_minimum_payment_cents) if input.key?(:summary_minimum_payment_cents)
          attributes[:debt_summary_minimum_payment_known] = input.fetch(:summary_minimum_payment_known) if input.key?(:summary_minimum_payment_known)
          profile.update!(attributes)
          profile
        end

        def canonical_after_snapshot(profile, _input, prepared:)
          canonical_snapshot(profile.reload, {}, lock: false)
        end

        def verify_after!(predicted, actual)
          return true if predicted == actual
          raise Operations::Runner::InvalidPreparedOperation, "The debt tracking choice did not match the reviewed change. Nothing changed."
        end

        def profile_snapshot(profile)
          {
            debt_tracking_mode: profile.debt_tracking_mode,
            debt_summary_balance_cents: profile.debt_summary_balance_cents,
            debt_summary_balance_known: profile.debt_summary_balance_known?,
            debt_summary_minimum_payment_cents: profile.debt_summary_minimum_payment_cents,
            debt_summary_minimum_payment_known: profile.debt_summary_minimum_payment_known?
          }
        end

        def active_debt_snapshots(lock:)
          scope = household.debts.active.order(:id)
          scope = scope.lock if lock
          scope.map do |debt|
            {
              id: debt.id,
              balance_cents: debt.balance_cents,
              balance_known: debt.balance_known?,
              minimum_payment_cents: debt.minimum_payment_cents,
              minimum_payment_known: debt.minimum_payment_known?
            }.stringify_keys
          end
        end

        def portfolio_snapshot(profile, debts)
          if profile.fetch("debt_tracking_mode") == "summary"
            {
              mode: "summary",
              balance_cents: profile.fetch("debt_summary_balance_cents"),
              balance_known: profile.fetch("debt_summary_balance_known"),
              minimum_payment_cents: profile.fetch("debt_summary_minimum_payment_cents"),
              minimum_payment_known: profile.fetch("debt_summary_minimum_payment_known"),
              active_count: debts.length
            }
          else
            {
              mode: "individual",
              balance_cents: debts.sum { |debt| debt.fetch("balance_cents") },
              balance_known: debts.any? && debts.all? { |debt| debt.fetch("balance_known") },
              minimum_payment_cents: debts.sum { |debt| debt.fetch("minimum_payment_cents") },
              minimum_payment_known: debts.any? && debts.all? { |debt| debt.fetch("minimum_payment_known") },
              active_count: debts.length
            }
          end
        end
      end
    end
  end
end
