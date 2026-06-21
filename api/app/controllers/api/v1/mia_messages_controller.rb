module Api
  module V1
    class MiaMessagesController < BaseController
      before_action :authenticate_user!

      def index
        render json: HouseholdFinance::DataPresenter.new(current_household, user: current_user).mia
      end

      def create
        content = params.require(:message).to_s.strip
        session = current_chat_session
        history = session.chat_messages.order(:created_at).last(12).map { |message| { role: message.role, content: message.content } }
        context = HouseholdFinance::MiaContextBuilder.new(current_household).call
        assistant_content = ::Demo::MiaResponder.new.call(content, history: history, context: context)

        user_message = session.chat_messages.create!(role: "user", content: content)
        assistant_message = session.chat_messages.create!(role: "assistant", content: assistant_content)

        render json: {
          user_message: user_message.as_api_json(author: "You"),
          assistant_message: assistant_message.as_api_json(author: "Mia")
        }, status: :created
      end

      def destroy
        current_chat_session.chat_messages.delete_all
        head :no_content
      end

      private

      def current_chat_session
        current_household.chat_sessions.find_or_create_by!(user: current_user) do |session|
          session.title = "Ask Mia"
        end
      end
    end
  end
end
