# frozen_string_literal: true

module Api
  module V1
    module Admin
      class CoachWorkspacesController < BaseController
        class CreationConflict < StandardError; end
        class OwnerInvalid < StandardError; end

        before_action :authenticate_user!
        before_action :require_staff!
        before_action :require_admin!, only: :create
        rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
        rescue_from ActiveRecord::RecordInvalid, with: :render_invalid
        rescue_from ActiveRecord::StaleObjectError, with: :render_conflict
        rescue_from CreationConflict, with: :render_creation_conflict
        rescue_from OwnerInvalid, with: :render_owner_invalid

        def show
          render json: { coach_workspace: detail(workspace) }
        end

        def create
          attributes = settings_params
          key = request_idempotency_key
          fingerprint_values = [ attributes[:name].to_s.squish, profile_attributes(attributes).sort.to_h, owner_email ]
          # Keep older default-send requests replayable across this release.
          fingerprint_values << { "send_invitation_email" => false } unless send_owner_invitation_email?
          fingerprint = Digest::SHA256.hexdigest(JSON.generate(fingerprint_values))
          invited_owner = nil
          current_user.with_lock do
            validate_creation_authority!
            existing = replay_created(key, fingerprint)
            return render json: { coach_workspace: detail(existing) } if existing

            record = CoachWorkspace.create!(
              name: attributes[:name],
              slug: "program-#{SecureRandom.uuid}",
              created_by_user: current_user,
              creation_request_key: key,
              creation_request_fingerprint: fingerprint
            )
            owner, invited_owner = resolve_owner!
            record.coach_workspace_memberships.create!(user: owner, role: "owner")
            CoachWorkspaces::OwnerCohortAccess.for_owner!(record, owner)
            record.create_coach_profile!(profile_attributes(attributes).merge(last_edited_by_user: current_user))
            Branding::Provisioner.ensure_for!(workspace: record, actor: current_user)
            @created = [ record, invited_owner ]
          end
          record, invited_owner = @created
          render json: { coach_workspace: detail(record), owner_invitation: owner_invitation(record, invited_owner) }, status: :created
        rescue ActiveRecord::RecordNotUnique
          current_user.with_lock do
            validate_creation_authority!
            existing = replay_created(key, fingerprint)
            raise unless existing

            render json: { coach_workspace: detail(existing) }
          end
        end

        def update
          record = workspace
          attributes = settings_params
          CoachWorkspaces::MutationAuthority.new(workspace: record, actor: current_user, permissions: :manage_members).call do |actor|
            return render_conflict unless Integer(attributes[:revision], exception: false) == record.lock_version

            record.update!(name: attributes[:name])
            profile = record.coach_profile || record.build_coach_profile
            profile.update!(profile_attributes(attributes).merge(last_edited_by_user: actor))
            # Profile and workspace identity share one revision and transaction.
            record.touch
          end
          render json: { coach_workspace: detail(record.reload) }
        end

        private

        # The platform admin may name the coach who will own the program. Admins
        # keep full authority through their platform role, so they do not need
        # a membership of their own. With no owner named, the admin owns it.
        def owner_email
          params.dig(:coach_workspace, :owner_email).to_s.strip.downcase
        end

        def send_owner_invitation_email?
          value = params.dig(:coach_workspace, :send_invitation_email)
          value.nil? || ActiveModel::Type::Boolean.new.cast(value)
        end

        def resolve_owner!
          email = owner_email
          return [ current_user, nil ] if email.blank? || email == current_user.email.to_s.downcase

          unless email.length <= 254 && email.match?(URI::MailTo::EMAIL_REGEXP)
            raise OwnerInvalid, "Enter a valid email address for the program owner."
          end
          user = User.where("LOWER(email) = ?", email).first
          if user
            if user.revoked?
              raise OwnerInvalid, "That account's access was removed, so it cannot own a program. Restore the account first."
            end
            unless user.staff?
              raise OwnerInvalid, "That email belongs to a participant account. Use the coach's own email, or leave it blank to own the program yourself."
            end
            [ user, nil ]
          else
            invited = User.create!(email: email, clerk_id: "pending_#{SecureRandom.uuid}", role: "coach",
              invitation_status: "pending", invited_at: Time.current, invited_by_user: current_user)
            [ invited, invited ]
          end
        end

        def owner_invitation(record, invited)
          return nil unless invited

          collaborators = CoachWorkspaces::Collaborators.new(workspace: record, actor: current_user)
          delivery = CoachWorkspaces::CollaboratorInviteEmail.send_invite(user: invited, workspace: record, role: "owner",
            invited_by: current_user, sign_in_url: collaborators.sign_in_url, requested: send_owner_invitation_email?)
          { email: invited.email, delivery: delivery }
        rescue StandardError => e
          Rails.logger.warn("[CoachWorkspaces] owner invitation email failed: #{e.class}")
          { email: invited.email, delivery: { sent: false, status: "failed" } }
        end

        def render_owner_invalid(error)
          render json: { error: error.message, code: "coach_workspace_owner_invalid" }, status: :unprocessable_entity
        end

        def validate_creation_authority!
          raise ActiveRecord::RecordNotFound unless current_user.admin? && current_user.invitation_accepted? && !current_user.revoked?
        end

        def render_creation_conflict(*)
          render json: { error: "This creation request was already used for different program settings.", code: "coach_workspace_creation_conflict" }, status: :conflict
        end

        def replay_created(key, fingerprint)
          existing = CoachWorkspace.find_by(created_by_user: current_user, creation_request_key: key)
          return nil unless existing
          raise CreationConflict unless ActiveSupport::SecurityUtils.secure_compare(existing.creation_request_fingerprint.to_s, fingerprint)

          existing
        end

        def workspace
          @workspace ||= CoachWorkspace.visible_to(current_user).includes(:coach_profile).find(params[:id])
        end

        def can_manage?(record)
          current_user.admin? || record.membership_for(current_user)&.role == "owner"
        end

        def detail(record)
          record.as_api_json(user: current_user).merge(
            revision: record.lock_version,
            permissions: { manage: can_manage?(record) }
          )
        end

        def settings_params
          params.require(:coach_workspace).permit(:name, :revision, coach_profile: %i[display_name title bio])
        end

        def profile_attributes(attributes)
          attributes.fetch(:coach_profile, {}).to_h.symbolize_keys.slice(:display_name, :title, :bio)
        end

        def render_conflict(*)
          render json: {
            error: "Program settings changed in another session. Reload before saving.",
            code: "coach_workspace_settings_stale"
          }, status: :conflict
        end

        def render_not_found(*)
          render json: { error: "Program settings are unavailable for this account.", code: "coach_workspace_not_found" }, status: :not_found
        end

        def render_invalid(error)
          render json: { errors: error.record.errors.full_messages, code: "coach_workspace_invalid" }, status: :unprocessable_entity
        end
      end
    end
  end
end
