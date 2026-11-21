module Api
  module V1
    # Balances offered from approved statements. Listing changes nothing; each
    # offer is applied only when the participant approves it.
    class StatementBalancesController < BaseController
      before_action :authenticate_user!
      before_action :require_writable_household!, only: :apply

      def index
        render json: { offers: writable? ? offers.map { |offer| present(offer) } : [] }
      end

      def apply
        target = params.require(:target).to_s
        kind = params.require(:kind).to_s
        raise ArgumentError, "Choose which account this statement belongs to" unless kind.in?(%w[account debt])

        input = { tracked_account_id: params.require(:tracked_account_id), offer_key: params.require(:offer_key).to_s }
        if target == "new"
          input[kind == "debt" ? :new_debt : :new_account] = true
          input[:new_type] = params[:new_type].to_s if params[:new_type].present?
        else
          input[kind == "debt" ? :debt_id : :account_id] = Integer(target, exception: false) || raise(ArgumentError, "Choose which account this statement belongs to")
        end
        runner = HouseholdFinance::Operations::Runner.new(current_household, user: current_user)
        runner.run(operation_key: "#{kind}.statement_balance.apply", input: input, idempotency_key: required_idempotency_key)
        render json: { offers: offers.map { |offer| present(offer) } }
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "That account is no longer available. Refresh to see the latest. Nothing changed." ] }, status: :not_found
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
        render json: { errors: [ "That account name is already in use. Nothing changed." ] }, status: :unprocessable_entity
      rescue HouseholdFinance::Operations::Base::StaleOperation => e
        render json: { errors: [ e.message ], code: "stale_review" }, status: :conflict
      rescue ArgumentError => e
        render_operation_error(e)
      end

      private

      def offers
        HouseholdFinance::StatementBalanceOffers.new(current_household.reload).call
      end

      def writable?
        current_household.household_memberships.find_by(user_id: current_user.id)&.role.in?(%w[owner partner])
      end

      def required_idempotency_key
        request.headers["Idempotency-Key"].to_s.strip.presence || raise(ArgumentError, "Idempotency-Key header is required")
      end

      def present(offer)
        row = ->(target) { target && target.merge(balance: target[:balance_cents]&.then { |cents| HouseholdFinance::Money.dollars(cents) }) }
        offer.slice(:key, :tracked_account_id, :kind, :statement_label, :as_of_on, :can_add_new, :new_label, :new_account_type, :new_type_options)
          .merge(balance: HouseholdFinance::Money.dollars(offer[:balance_cents]), balance_cents: offer[:balance_cents],
            target: row.call(offer[:target]), choices: offer[:choices].map(&row))
      end
    end
  end
end
