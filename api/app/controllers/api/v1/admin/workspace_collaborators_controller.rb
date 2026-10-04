# frozen_string_literal: true

module Api
  module V1
    module Admin
      class WorkspaceCollaboratorsController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!
        before_action :require_selected_coach_workspace!
        rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
        rescue_from CoachWorkspaces::Collaborators::Conflict, with: :render_conflict
        rescue_from CoachWorkspaces::Collaborators::Invalid, with: :render_invalid
        rescue_from ActiveRecord::RecordInvalid, with: :render_record_invalid

        def index
          render json: collaborators.list
        end

        def create
          result = collaborators.add(email: input[:email], role: input[:role])
          delivery = result[:added] ? send_access_email(result.fetch(:user), input[:role], requested: ActiveModel::Type::Boolean.new.cast(input[:send_email])) : nil
          render json: { member: result[:member], new_user: result[:new_user], added: result[:added], delivery: delivery, sign_in_url: collaborators.sign_in_url }, status: result[:added] ? :created : :ok
        end

        def update
          member = collaborators.change(id: params[:id], role: input[:role], expected_role: input[:expected_role])
          render json: { member: member }
        end

        def destroy
          result = collaborators.remove(id: params[:id], expected_role: input[:expected_role])
          render json: { removed: true, platform_admin: result[:platform_admin] }
        end

        def send_invitation
          collaborators.list # authorize before resolving any member data
          membership = current_coach_workspace.coach_workspace_memberships.includes(:user).find(params[:id])
          raise CoachWorkspaces::Collaborators::Invalid, "This account needs a platform administrator to restore access before sending an invitation." if membership.user.revoked?

          render json: { delivery: send_access_email(membership.user, membership.role, requested: true), sign_in_url: collaborators.sign_in_url }
        end

        private

        def collaborators
          @collaborators ||= CoachWorkspaces::Collaborators.new(workspace: current_coach_workspace, actor: current_user)
        end

        def input
          @input ||= params.require(:collaborator)
            .permit(:email, :role, :expected_role, :send_email)
            .to_h
            .symbolize_keys
        end

        def send_access_email(user, role, requested:)
          CoachWorkspaces::CollaboratorInviteEmail.send_invite(user: user, workspace: current_coach_workspace, role: role,
            invited_by: current_user, sign_in_url: collaborators.sign_in_url, requested: requested)
        end

        def render_not_found
          render json: { error: "Collaborator management is available to workspace owners and platform administrators.", code: "workspace_collaborators_unavailable" }, status: :not_found
        end

        def render_conflict(error)
          render json: { error: error.message, code: "workspace_collaborator_conflict" }, status: :conflict
        end

        def render_invalid(error)
          render json: { error: error.message, code: "workspace_collaborator_invalid" }, status: :unprocessable_entity
        end

        def render_record_invalid(error)
          render json: { error: error.record.errors.full_messages.first, code: "workspace_collaborator_invalid" }, status: :unprocessable_entity
        end
      end
    end
  end
end
