module Api
  module Demo
    class HouseholdsController < ApplicationController
      def profile
        render json: ::Demo::HouseholdData.profile
      end

      def dashboard
        render json: ::Demo::HouseholdData.dashboard
      end

      def optionality
        render json: ::Demo::HouseholdData.optionality
      end

      def cfo_filter
        render json: ::Demo::HouseholdData.cfo_filter
      end
    end
  end
end
