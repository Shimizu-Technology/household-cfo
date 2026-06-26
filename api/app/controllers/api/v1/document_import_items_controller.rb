module Api
  module V1
    class DocumentImportItemsController < BaseController
      before_action :authenticate_user!
      before_action :set_document_import
      before_action :set_item

      def update
        return render json: { errors: [ "Applied extracted values cannot be edited" ] }, status: :unprocessable_entity if @item.applied?

        @item.update!(item_update_attributes)
        render json: { item: serialize_item(@item.reload) }
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      private

      def set_document_import
        @document_import = current_household.financial_document_imports.find(params[:document_import_id])
      end

      def set_item
        @item = @document_import.items.find(params[:id])
      end

      def item_params
        params.require(:item).permit(
          :target_type,
          :label,
          :amount,
          :amount_cents,
          :balance,
          :balance_cents,
          :payment,
          :payment_cents,
          :cadence,
          :source_type,
          :stack_key,
          :account_type,
          :debt_type,
          :confidence,
          :evidence,
          :selected,
          :ignored
        )
      end

      def item_update_attributes
        attributes = item_params.to_h.symbolize_keys.slice(
          :target_type,
          :label,
          :amount_cents,
          :balance_cents,
          :payment_cents,
          :cadence,
          :source_type,
          :stack_key,
          :account_type,
          :debt_type,
          :confidence,
          :evidence,
          :selected,
          :ignored
        )
        attributes[:amount_cents] = HouseholdFinance::Money.cents(item_params[:amount]) if item_params.key?(:amount)
        attributes[:balance_cents] = HouseholdFinance::Money.cents(item_params[:balance]) if item_params.key?(:balance)
        attributes[:payment_cents] = HouseholdFinance::Money.cents(item_params[:payment]) if item_params.key?(:payment)
        attributes[:label] = bounded_text(attributes[:label], 120) if attributes.key?(:label)
        attributes[:evidence] = bounded_text(attributes[:evidence], 1000) if attributes.key?(:evidence)
        attributes
      end

      def bounded_text(value, max_length)
        value.to_s.unicode_normalize(:nfkc).gsub(/[[:cntrl:]]/, " ").gsub(/[<>`]/, "").squish.truncate(max_length, omission: "…")
      end

      def serialize_item(item)
        {
          id: item.id,
          target_type: item.target_type,
          label: item.label,
          amount: dollars_or_nil(item.amount_cents),
          amount_cents: item.amount_cents,
          balance: dollars_or_nil(item.balance_cents),
          balance_cents: item.balance_cents,
          payment: dollars_or_nil(item.payment_cents),
          payment_cents: item.payment_cents,
          cadence: item.cadence,
          source_type: item.source_type,
          stack_key: item.stack_key,
          account_type: item.account_type,
          debt_type: item.debt_type,
          confidence: item.confidence,
          evidence: item.evidence,
          selected: item.selected,
          ignored: item.ignored,
          applied_at: item.applied_at,
          applied_record_type: item.applied_record_type,
          applied_record_id: item.applied_record_id,
          metadata: item.metadata || {}
        }
      end

      def dollars_or_nil(cents)
        return nil if cents.nil?

        HouseholdFinance::Money.dollars(cents)
      end
    end
  end
end
