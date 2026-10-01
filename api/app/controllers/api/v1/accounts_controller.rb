module Api
  module V1
    class AccountsController < BaseController
      before_action :authenticate_user!
      before_action :require_writable_household!

      def create
        input = account_params.to_h.merge(source_type: "manual_ui")
        input[:balance_state] = input.key?("balance") && input["balance"].present? ? "known" : "unknown" unless input.key?("balance_state")
        result = runner.run(operation_key: "account.record.create", input: input, idempotency_key: required_idempotency_key)
        render_account_response(result.subject, status: :created)
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ActiveRecord::RecordNotUnique
        render json: { errors: [ "That account name or bank match is already in use" ] }, status: :unprocessable_entity
      rescue ArgumentError => e
        render_operation_error(e)
      end

      def update
        input = account_params.to_h.merge(account_id: scoped_account.id)
        input[:balance_state] = input["balance"].present? ? "known" : "unknown" if input.key?("balance") && !input.key?("balance_state")
        result = runner.run(operation_key: "account.record.update", input: input, idempotency_key: required_idempotency_key)
        render_account_response(result.subject)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Account not found" ] }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ActiveRecord::RecordNotUnique
        render json: { errors: [ "That account name or bank match is already in use" ] }, status: :unprocessable_entity
      rescue ArgumentError => e
        render_operation_error(e)
      end

      def destroy
        result = run_for_account("account.record.archive")
        render_account_response(result.subject)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Account not found" ] }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ArgumentError => e
        render_operation_error(e)
      end

      def restore
        result = run_for_account("account.record.restore")
        render_account_response(result.subject)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Account not found" ] }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ActiveRecord::RecordNotUnique
        render json: { errors: [ "An active account already uses that name and type" ] }, status: :unprocessable_entity
      rescue ArgumentError => e
        render_operation_error(e)
      end

      def plaid_link
        result = runner.run(operation_key: "account.plaid.link", input: { account_id: scoped_account.id, plaid_account_id: params.require(:plaid_account_id) }, idempotency_key: required_idempotency_key)
        render_account_response(result.subject)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Account or bank observation not found" ] }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ActiveRecord::RecordNotUnique
        render json: { errors: [ "That bank account is already matched" ] }, status: :unprocessable_entity
      rescue ArgumentError => e
        render_operation_error(e)
      end

      def plaid_reconcile
        result = runner.run(operation_key: "account.plaid.reconcile", input: { account_id: scoped_account.id, decision: params.require(:decision) }, idempotency_key: required_idempotency_key)
        render_account_response(result.subject)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Account or bank observation not found" ] }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ArgumentError => e
        render_operation_error(e)
      end

      def plaid_unlink
        result = run_for_account("account.plaid.unlink")
        render_account_response(result.subject)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Account not found" ] }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ArgumentError => e
        render_operation_error(e)
      end

      private

      def runner
        @runner ||= HouseholdFinance::Operations::Runner.new(current_household, user: current_user)
      end

      def run_for_account(key)
        runner.run(operation_key: key, input: { account_id: scoped_account.id }, idempotency_key: required_idempotency_key)
      end

      def required_idempotency_key
        request.headers["Idempotency-Key"].to_s.strip.presence || raise(ArgumentError, "Idempotency-Key header is required")
      end

      def scoped_account
        @scoped_account ||= current_household.accounts.find(params[:id])
      end

      def account_params
        params.fetch(:account, {}).permit(:label, :account_type, :balance, :balance_state, :balance_as_of_on, :plaid_account_id)
      end

      def render_account_response(account, status: :ok)
        presenter = HouseholdFinance::DataPresenter.new(current_household.reload, user: current_user)
        render json: { account: presenter.account_records.find { |row| row.fetch(:id) == account.id }, asset_portfolio: HouseholdFinance::AssetPortfolio.new(current_household).as_json }, status: status
      end
    end
  end
end
