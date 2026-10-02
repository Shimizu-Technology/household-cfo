module Api
  module V1
    class BaseController < ApplicationController
      include ClerkAuthenticatable

      private

      def current_household
        @current_household ||= HouseholdFinance::WorkspaceResolver.new(current_user).household
      end

      def current_cohort_membership
        return @current_cohort_membership if defined?(@current_cohort_membership)

        @current_cohort_membership = ::Mia::EffectiveCohortResolver.new(
          user: current_user,
          role: "participant"
        ).call
      end

      def current_persona
        return @current_persona if defined?(@current_persona)

        @current_persona = ::Mia::PersonaResolver.new(
          user: current_user,
          cohort_membership: current_cohort_membership
        ).call
      end

      def current_experience_capabilities
        @current_experience_capabilities ||= CohortExperience::EffectiveCapabilitiesResolver.new(
          cohort_membership: current_cohort_membership
        ).call
      end

      def current_coach_workspace
        @current_coach_workspace ||= CoachWorkspaces::Resolver.new(
          user: current_user,
          requested_id: request.headers["X-Coach-Workspace-Id"]
        ).call
      end

      def coach_workspace_for_policy
        return nil if current_user.admin? && request.headers["X-Coach-Workspace-Id"].blank?

        current_coach_workspace
      end

      def require_experience_module!(module_id)
        item = current_experience_capabilities.fetch(:modules).find { |candidate| candidate.fetch(:id) == module_id.to_s }
        return if item&.fetch(:enabled, false)

        message = item&.fetch(:unavailable_message, nil) || "This tool is not included in your cohort right now."
        render json: {
          error: message,
          errors: [ message ],
          code: "module_disabled",
          module_id: module_id.to_s,
          redirect_section: "Home"
        }, status: :forbidden
      end

      def require_writable_household!
        membership = current_household.household_memberships.find_by(user_id: current_user.id)
        return if membership&.role.in?(%w[owner partner])

        render json: { errors: [ "This household is read-only for your account." ] }, status: :forbidden
      end

      def render_current_workspace
        render json: current_workspace_data
      end

      def request_idempotency_key
        request.headers["Idempotency-Key"].to_s.strip.presence || SecureRandom.uuid
      end

      def render_operation_error(error)
        status = error.is_a?(HouseholdFinance::Operations::Runner::IdempotencyConflict) ? :conflict : :unprocessable_entity
        render json: { errors: [ error.message ] }, status: status
      end

      def current_workspace_data
        current_data_presenter.app_data
      end

      def current_data_presenter(household: current_household, annual_plan: nil, ensure_plan: true)
        HouseholdFinance::DataPresenter.new(
          household,
          user: current_user,
          annual_plan: annual_plan,
          ensure_plan: ensure_plan,
          persona: current_persona,
          cohort_membership: current_cohort_membership,
          experience_capabilities: current_experience_capabilities
        )
      end
    end
  end
end
