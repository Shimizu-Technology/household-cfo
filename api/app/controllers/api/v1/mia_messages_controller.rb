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
        context = HouseholdFinance::MiaContextBuilder.new(current_household).call
        assistant_content = ::Demo::MiaResponder.new.call(content, history: history, context: context)

        user_message, assistant_message = ApplicationRecord.transaction do
          [
            session.chat_messages.create!(role: "user", content: content),
            session.chat_messages.create!(role: "assistant", content: assistant_content)
          ]
        end

        render json: {
          user_message: user_message.as_api_json(author: "You"),
          assistant_message: assistant_message.as_api_json(author: "Mia")
        }, status: :created
      end

      def destroy
        current_household.chat_sessions.find_by(user: current_user)&.chat_messages&.delete_all
        head :no_content
      end

      private

      def current_chat_session
        current_household.chat_sessions.find_by(user: current_user) ||
          current_household.chat_sessions.create!(user: current_user, title: "Ask Mia")
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
        current_household.chat_sessions.find_by!(user: current_user)
      end
    end
  end
end
