module HouseholdFinance
  module Operations
    # Shared rules for approving a balance offered from a statement. The offer is
    # recomputed inside the household lock; the participant's reviewed offer key
    # must still match, so a newer statement or an edit since she looked
    # changes nothing.
    module StatementBalance
      STALE = "Your statements or accounts changed since this was shown. Refresh to see the latest. Nothing changed.".freeze
      OFFER_KEY = /\A[0-9a-f]{64}\z/

      private

      def normalize_offer_input(input, id_key:, new_key:)
        values = { tracked_account_id: Integer(input.fetch(:tracked_account_id)), offer_key: input.fetch(:offer_key).to_s }
        raise ArgumentError, "Review the current statement balance" unless values[:offer_key].match?(OFFER_KEY)

        if input[id_key].present?
          values[id_key] = Integer(input[id_key])
        elsif input[new_key] == true
          values[new_key] = true
        else
          raise ArgumentError, "Choose which account this statement belongs to"
        end
        values
      rescue KeyError, TypeError
        raise ArgumentError, "Review the current statement balance"
      end

      def current_offer(input)
        offer = StatementBalanceOffers.new(household).find(input[:tracked_account_id])
        offer&.deep_stringify_keys
      end

      def reviewed_offer!(before, input, kind)
        offer = before["offer"]
        raise Operations::Base::StaleOperation, STALE unless offer && offer["kind"] == kind && offer["key"] == input[:offer_key]
        offer
      end

      def chosen_target!(offer, id)
        linked = offer["choices"].empty? && offer.dig("target", "id") == id
        return if linked || offer["choices"].any? { |choice| choice["id"] == id }

        raise Operations::Base::StaleOperation, STALE
      end

      def statement_metadata(existing, offer)
        (existing.is_a?(Hash) ? existing : {}).merge(StatementBalanceOffers::METADATA_KEY => StatementBalanceOffers.provenance(offer.deep_symbolize_keys))
      end

      def stale_message = STALE
    end
  end
end
