module Api
  module V1
    class MiaMessagesController < BaseController
      before_action :authenticate_user!

      def index
        render json: HouseholdFinance::DataPresenter.new(current_household, user: current_user).mia
      end

      def create
        content = params.require(:message).to_s.strip
        return render json: { errors: [ "Message can't be blank" ] }, status: :unprocessable_entity if content.blank?
        return render json: { errors: [ "Message is too long (maximum is #{ChatMessage::MAX_CONTENT_LENGTH} characters)" ] }, status: :unprocessable_entity if content.length > ChatMessage::MAX_CONTENT_LENGTH

        session = current_chat_session
        history = session.chat_messages.order(:created_at).last(12).map { |message| { role: message.role, content: message.content } }
        annual_budget_manager = HouseholdFinance::AnnualBudgetManager.new(current_household)
        annual_plan = annual_budget_manager.plan_data
        context = HouseholdFinance::MiaContextBuilder.new(current_household, annual_plan: annual_plan).call
        assistant_content = ::Demo::MiaResponder.new.call(content, history: history, context: context)
        transaction_draft = nil

        user_message, assistant_message = ApplicationRecord.transaction do
          transaction_draft = HouseholdFinance::TransactionDraftBuilder.new(
            current_household,
            content,
            annual_budget_manager: annual_budget_manager,
            plan_prepared: true
          ).call
          [
            session.chat_messages.create!(role: "user", content: content),
            session.chat_messages.create!(role: "assistant", content: assistant_content)
          ]
        end

        annual_plan = annual_budget_manager.plan_data if transaction_draft

        render json: {
          user_message: user_message.as_api_json(author: "You"),
          assistant_message: assistant_message.as_api_json(author: "Mia"),
          transaction_draft: transaction_draft ? serialize_transaction_draft(transaction_draft) : nil,
          budget: HouseholdFinance::DataPresenter.new(current_household.reload, user: current_user, annual_plan: annual_plan).budget
        }, status: :created
      end

      def destroy
        current_household.chat_sessions.find_by(user: current_user)&.chat_messages&.delete_all
        head :no_content
      end

      private

      def serialize_transaction_draft(draft)
        {
          id: draft.id,
          occurred_on: draft.occurred_on.iso8601,
          merchant: draft.merchant,
          amount: HouseholdFinance::Money.dollars(draft.total_amount_cents),
          status: draft.status,
          source_type: draft.source_type,
          category_id: draft.budget_category_id,
          category_name: draft.budget_category&.name,
          stack_label: draft.budget_category&.stack_label,
          summary: "#{draft.merchant} — #{ActionController::Base.helpers.number_to_currency(HouseholdFinance::Money.dollars(draft.total_amount_cents), precision: 2)}"
        }
      end

      def current_chat_session
        current_household.chat_sessions.find_by(user: current_user) ||
          current_household.chat_sessions.create!(user: current_user, title: "Ask Mia")
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
        current_household.chat_sessions.find_by!(user: current_user)
      end
    end
  end
end
