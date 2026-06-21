module Api
  module Demo
    class MiaMessagesController < ApplicationController
      include ClerkAuthenticatable

      before_action :authenticate_user_if_clerk_configured!

      def index
        render json: ::Demo::HouseholdData.mia_messages
      end

      def create
        content = params.require(:message)
        assistant_content = ::Demo::MiaResponder.new.call(content, history: conversation_history)

        render json: {
          user_message: {
            role: "user",
            author: "You",
            content: content
          },
          assistant_message: {
            role: "assistant",
            author: "Mia",
            content: assistant_content
          }
        }, status: :created
      end

      private

      def conversation_history
        Array(params[:messages]).filter_map do |message|
          permitted = message.respond_to?(:permit) ? message.permit(:role, :content).to_h : message.to_h
          role = permitted["role"].to_s
          content = permitted["content"].to_s.strip

          next unless role.in?([ "assistant", "user" ]) && content.present?

          { role: role, content: content }
        end.last(12)
      end
    end
  end
end
