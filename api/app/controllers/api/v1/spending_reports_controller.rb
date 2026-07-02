module Api
  module V1
    class SpendingReportsController < BaseController
      before_action :authenticate_user!

      def show
        range = report_range
        render json: { spending_report: HouseholdFinance::SpendingReport.new(current_household, start_on: range.fetch(:start_on), end_on: range.fetch(:end_on)).as_json }
      rescue ArgumentError
        render json: { errors: [ "Invalid report date range" ] }, status: :unprocessable_entity
      end

      private

      def report_range
        start_on = params[:start_on].present? ? Date.iso8601(params[:start_on].to_s) : Date.current.beginning_of_month
        end_on = params[:end_on].present? ? Date.iso8601(params[:end_on].to_s) : start_on.end_of_month
        raise ArgumentError if end_on < start_on

        { start_on: start_on, end_on: end_on }
      end
    end
  end
end
