module Api
  module V1
    class DocumentImportItemsController < BaseController
      before_action :authenticate_user!
      before_action :set_document_import
      before_action :set_item

      def update
        attributes = item_update_attributes
        if @item.applied?
          result = HouseholdFinance::AppliedDocumentImportItemUpdater.new(@item, user: current_user, attributes: attributes).call
          return render json: { errors: result.errors }, status: :unprocessable_entity unless result.success?

          return render json: { item: serialize_item(result.item) }
        end

        ApplicationRecord.transaction do
          @document_import.with_lock do
            @item.update!(attributes)
            HouseholdFinance::DocumentImportStatusReconciler.new(@document_import).call
          end
        end
        render json: { item: serialize_item(@item.reload) }
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ArgumentError => e
        render json: { errors: [ e.message ] }, status: :unprocessable_entity
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
        raw_attributes = item_params.to_h.symbolize_keys
        attributes = raw_attributes.slice(
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
        attributes[:amount_cents] = HouseholdFinance::Money.cents(raw_attributes[:amount]) if raw_attributes.key?(:amount)
        attributes[:balance_cents] = HouseholdFinance::Money.cents(raw_attributes[:balance]) if raw_attributes.key?(:balance)
        attributes[:payment_cents] = HouseholdFinance::Money.cents(raw_attributes[:payment]) if raw_attributes.key?(:payment)
        attributes[:label] = bounded_text(attributes[:label], 120) if attributes.key?(:label)
        attributes[:evidence] = bounded_text(attributes[:evidence], 1000) if attributes.key?(:evidence)
        normalize_selection_flags!(attributes)
        attributes
      end

      def normalize_selection_flags!(attributes)
        return unless attributes.key?(:selected) || attributes.key?(:ignored)

        attributes[:selected] = boolean_value(attributes[:selected]) if attributes.key?(:selected)
        attributes[:ignored] = boolean_value(attributes[:ignored]) if attributes.key?(:ignored)
        return if attributes.key?(:selected) && attributes.key?(:ignored)

        attributes[:selected] = false if attributes[:ignored]
        attributes[:ignored] = false if attributes[:selected]
      end

      def boolean_value(value)
        ActiveModel::Type::Boolean.new.cast(value)
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
