require_relative "base"

module HouseholdFinance
  module Operations
    module Debt
      # Sets a card or loan's balance owed to the closing balance on its latest
      # approved statement. With new_debt, adds it to her debts as the kind she
      # chose; its minimum payment stays unknown until she enters it.
      class StatementBalanceApply < Base
        include Operations::StatementBalance

        KEY = "debt.statement_balance.apply"
        VERSION = 1

        private

        def normalize(input) = normalize_offer_input(input, id_key: :debt_id, new_key: :new_debt)

        def subject_for(input, lock:)
          return debt_scope(lock: lock).find(input[:debt_id]) if input[:debt_id]

          lock ? household.lock! : household
        end

        def canonical_snapshot(subject, input, lock:)
          offer = current_offer(input)
          conflicts = input[:new_debt] && offer&.fetch("new_label", nil) ? conflict_ids(label: offer.fetch("new_label"), debt_type: new_type(offer, input), lock: lock) : []
          { debt: subject.is_a?(::Debt) ? debt_snapshot(subject).fetch(:debt) : nil, offer: offer, conflicting_debt_ids: conflicts }
        end

        def predicted_after(before, input)
          offer = reviewed_offer!(before, input, "debt")
          base = before["debt"] || { "label" => offer["new_label"], "debt_type" => new_type(offer, input), "minimum_payment_cents" => 0,
            "minimum_payment_known" => false, "interest_rate_percent" => nil, "active" => true, "archived_at" => nil }
          debt = base.merge("balance_cents" => offer.fetch("balance_cents"), "balance_known" => true,
            "source_type" => "document_import", "source_metadata" => statement_metadata(base["source_metadata"], offer))
          { debt: debt }
        end

        def validate_execution!(subject, input, prepared:, source:)
          offer = reviewed_offer!(prepared.before_snapshot, input, "debt")
          if input[:debt_id]
            raise ArgumentError, "Restore this debt before updating it. Nothing changed." unless subject.active?
            chosen_target!(offer, subject.id)
          else
            raise Operations::Base::StaleOperation, stale_message unless offer["can_add_new"] && offer["new_label"].present?
            raise ArgumentError, "An active debt already uses that name and type. Nothing changed." if prepared.before_snapshot.fetch("conflicting_debt_ids").any?
          end
        end

        def mutate!(subject, input, prepared:)
          after = prepared.predicted_after_snapshot.fetch("debt")
          attrs = { balance_cents: after.fetch("balance_cents"), balance_known: true, source_type: "document_import", source_metadata: after.fetch("source_metadata") }
          return subject.tap { |debt| debt.update!(attrs) } if input[:debt_id]

          household.debts.create!(attrs.merge(label: after.fetch("label"), debt_type: after.fetch("debt_type"), minimum_payment_cents: 0,
            minimum_payment_known: false, active: true, archived_at: nil))
        end

        def canonical_after_snapshot(debt, _input, prepared:) = debt_snapshot(debt.reload)
        def verify_after!(predicted, actual) = verify_debt_prediction!(predicted, actual)
      end
    end
  end
end
