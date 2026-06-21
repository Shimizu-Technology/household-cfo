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
        assistant_content = ::Demo::MiaResponder.new.call(content)

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
    end
  end
end
