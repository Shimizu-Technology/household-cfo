module Api
  module V1
    class BaseController < ApplicationController
      include ClerkAuthenticatable

      class InvalidIdempotencyKey < StandardError; end

      rescue_from ::Mia::EffectiveCohortResolver::InvalidSelection, with: :render_invalid_cohort_selection
      rescue_from InvalidIdempotencyKey, with: :render_invalid_idempotency_key

      rescue_from ChallengePrivacy::PrivateFinanceAccess::Denied do |error|
        response.set_header("Cache-Control", "private, no-store")
        render json: { errors: [ error.message ] }, status: :forbidden
      end

      private

      def current_household
        @current_household ||= HouseholdFinance::WorkspaceResolver.new(current_user).household
        ChallengePrivacy::PrivateFinanceAccess.authorize!(@current_household, user: current_user)
        @current_household
      end

      def current_cohort_membership
        current_participant_runtime.membership
      end

      def current_persona
        return @current_persona if defined?(@current_persona)

        @current_persona = current_participant_runtime.persona
      end

      def current_experience_capabilities
        @current_experience_capabilities ||= current_participant_runtime.capabilities
      end

      def current_brand
        @current_brand ||= current_participant_runtime.brand
      end

      def current_participant_runtime
        @current_participant_runtime ||= begin
          brand_workspace = participant_brand_workspace
          membership = ::Mia::EffectiveCohortResolver.new(
            user: current_user,
            role: "participant",
            requested_cohort_id: request&.headers&.[]("X-Cohort-Id"),
            coach_workspace: brand_workspace
          ).call
          ::Mia::ParticipantRuntimeResolver.new(
            user: current_user,
            cohort_membership: membership,
            coach_workspace: brand_workspace
          ).call
        end
      end

      def participant_brand_workspace
        return @participant_brand_workspace if defined?(@participant_brand_workspace)

        raw_hostname = request&.headers&.[]("X-Brand-Hostname").to_s.strip
        hostname = Branding::Hostname.normalize(raw_hostname) if raw_hostname.present?
        reject_unavailable_brand! if raw_hostname.present? && hostname.nil?

        raw_origin = request&.headers&.[]("Origin").to_s.strip
        origin_hostname = Branding::Hostname.from_origin(raw_origin) if raw_origin.present?
        reject_unavailable_brand! if raw_origin.present? && origin_hostname.nil?

        if origin_hostname
          origin_workspace_id = Branding::ActiveDomainRegistry.workspace_id_for(origin_hostname)
          if origin_workspace_id
            reject_unavailable_brand! unless hostname == origin_hostname
            return @participant_brand_workspace = CoachWorkspace.find(origin_workspace_id)
          end

          if Branding::Hostname::LOCAL.include?(origin_hostname)
            return @participant_brand_workspace = resolve_header_brand(hostname) if !Rails.env.production? && hostname.present?
            return @participant_brand_workspace = nil if hostname.blank? || hostname == origin_hostname
          elsif Branding::Hostname.legacy?(origin_hostname)
            return @participant_brand_workspace = nil if hostname.blank? || hostname == origin_hostname
          end

          reject_unavailable_brand! if hostname.present?
        end

        return @participant_brand_workspace = nil if hostname.blank?

        @participant_brand_workspace = resolve_header_brand(hostname)
      end

      def resolve_header_brand(hostname)
        return nil if Branding::Hostname::LOCAL.include?(hostname) || Branding::Hostname.legacy?(hostname)

        workspace_id = Branding::ActiveDomainRegistry.workspace_id_for(hostname)
        workspace_id ? CoachWorkspace.find(workspace_id) : reject_unavailable_brand!
      end

      def reject_unavailable_brand!
        raise ::Mia::EffectiveCohortResolver::InvalidSelection, "This coaching program link is unavailable."
      end

      def render_invalid_cohort_selection(error)
        render json: { error: error.message, code: "cohort_selection_invalid" }, status: :unprocessable_entity
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

      def require_selected_coach_workspace!
        return if coach_workspace_for_policy

        render json: {
          error: "Choose a coach workspace before creating workspace-owned records.",
          code: "coach_workspace_required"
        }, status: :unprocessable_entity
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
        key = request.headers["Idempotency-Key"].to_s.strip.presence || SecureRandom.uuid
        raise InvalidIdempotencyKey, "Idempotency-Key must be 255 characters or fewer." if key.length > 255

        key
      end

      def render_invalid_idempotency_key(error)
        render json: { error: error.message, code: "idempotency_key_invalid" }, status: :unprocessable_entity
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
          experience_capabilities: current_experience_capabilities,
          brand: current_brand
        )
      end
    end
  end
end
