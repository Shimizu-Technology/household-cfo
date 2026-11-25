module Api
  module V1
    # What Home leads with for the signed-in person: this month or the year. A person's
    # own choice; null goes back to the program's method setting.
    class HomeViewsController < BaseController
      before_action :authenticate_user!

      def update
        choice = params.require(:home_view).permit(:chosen)[:chosen].presence
        unless choice.nil? || HouseholdMembership::HOME_VIEWS.include?(choice)
          return render json: { errors: [ "Choose month or year." ] }, status: :unprocessable_entity
        end

        membership = current_household.household_memberships.find_by(user_id: current_user.id)
        return render json: { errors: [ "Home view can only be saved for your own household." ] }, status: :forbidden unless membership

        membership.update!(home_view: choice) unless membership.home_view == choice
        render json: { home_view: HouseholdFinance::HomeView.payload(CohortExperience::MethodSettings.for_household(current_household), membership: membership) }
      rescue ActiveRecord::ActiveRecordError => error
        Rails.logger.error("[HomeViewsController] home view write failed error=#{error.class}")
        render json: { errors: [ "Home view could not be saved right now. Please try again." ] }, status: :service_unavailable
      end
    end
  end
end
