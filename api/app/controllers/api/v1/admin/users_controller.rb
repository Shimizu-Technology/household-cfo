module Api
  module V1
    module Admin
      class UsersController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!

        def index
          users = User.includes(:invited_by_user, cohort_memberships: :cohort, household_memberships: :household).order(:email)
          render json: { users: users.map { |user| serialize_user(user) } }
        end

        def create
          role = requested_role
          return render json: { errors: [ "Role is not valid" ] }, status: :unprocessable_entity unless User::ROLES.include?(role)
          return render_forbidden("Role assignment not permitted") unless role_assignable_by_current_user?(role)

          user = nil
          User.transaction do
            user = User.create!(
              email: user_params[:email],
              first_name: bounded_text(user_params[:first_name], 80),
              last_name: bounded_text(user_params[:last_name], 80),
              role: role,
              clerk_id: pending_clerk_id,
              invitation_status: "pending",
              invited_at: Time.current,
              invited_by_user: current_user
            )
            sync_cohort_memberships(user, cohort_ids_from_params, role: cohort_role_for(role))
          end

          render json: { user: serialize_user(user.reload) }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotFound => e
          render json: { errors: [ e.message ] }, status: :unprocessable_entity
        end

        def update
          user = User.find(params[:id])
          attributes = user_update_params
          role = attributes[:role].presence || user.role
          return render json: { errors: [ "Role is not valid" ] }, status: :unprocessable_entity unless User::ROLES.include?(role)
          return render_forbidden("User update not permitted") unless user_update_permitted_by_current_user?(user, role)

          admin_guard_error = nil
          User.transaction do
            locked_admin_ids = admin_change_may_require_guard?(user, role:, requested_status: attributes[:invitation_status]) ? locked_active_admin_ids : nil
            user.lock!
            role = attributes[:role].presence || user.role
            normalized_status = normalized_invitation_status(user, attributes[:invitation_status])
            if admin_access_removal?(user, role:, invitation_status: normalized_status)
              locked_admin_ids ||= locked_active_admin_ids
              admin_guard_error = admin_change_error(user, locked_admin_ids: locked_admin_ids)
              raise ActiveRecord::Rollback if admin_guard_error
            end

            update_attributes = {
              role: role,
              invitation_status: normalized_status
            }
            update_attributes[:first_name] = bounded_text(attributes[:first_name], 80) if attributes.key?(:first_name)
            update_attributes[:last_name] = bounded_text(attributes[:last_name], 80) if attributes.key?(:last_name)
            user.assign_attributes(update_attributes)
            user.invited_at ||= Time.current if user.invitation_status == "pending"
            user.save!

            if cohort_membership_params_present?
              sync_cohort_memberships(user, cohort_ids_from_params, role: cohort_role_for(user.role))
            else
              user.cohort_memberships.update_all(role: cohort_role_for(user.role), updated_at: Time.current)
            end
          end

          if admin_guard_error
            render_admin_guard_error(admin_guard_error)
            return
          end

          render json: { user: serialize_user(user.reload) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotFound => e
          render json: { errors: [ e.message ] }, status: :unprocessable_entity
        end

        private

        def user_params
          payload = params.require(:user)
          permitted = payload.permit(:email, :first_name, :last_name, :cohort_id, cohort_ids: []).to_h.symbolize_keys
          permitted[:role] = payload[:role] if payload.key?(:role)
          permitted
        end

        def user_update_params
          payload = params.require(:user)
          permitted = payload.permit(:first_name, :last_name, :cohort_id, cohort_ids: []).to_h.symbolize_keys
          permitted[:role] = payload[:role] if payload.key?(:role)
          permitted[:invitation_status] = payload[:invitation_status] if payload.key?(:invitation_status)
          permitted.compact
        end

        def requested_role
          user_params[:role].presence || "participant"
        end

        def role_assignable_by_current_user?(role)
          return true if current_user.admin?

          current_user.coach? && role == "participant"
        end

        def user_update_permitted_by_current_user?(user, requested_role)
          return true if current_user.admin?

          current_user.coach? && user.participant? && requested_role == "participant"
        end

        def admin_change_may_require_guard?(user, role:, requested_status:)
          user.admin? && (role != "admin" || requested_status == "revoked")
        end

        def admin_access_removal?(user, role:, invitation_status:)
          user.admin? && !user.revoked? && (role != "admin" || invitation_status == "revoked")
        end

        def admin_change_error(user, locked_admin_ids:)
          return { status: :forbidden, message: "You cannot remove your own admin access" } if user == current_user
          return if (locked_admin_ids - [ user.id ]).any?

          { status: :unprocessable_entity, errors: [ "At least one active admin is required" ] }
        end

        def locked_active_admin_ids
          User.where(role: "admin")
            .where.not(invitation_status: "revoked")
            .order(:id)
            .lock("FOR UPDATE")
            .pluck(:id)
        end

        def render_admin_guard_error(error)
          return render_forbidden(error.fetch(:message)) if error.fetch(:status) == :forbidden

          render json: { errors: error.fetch(:errors) }, status: error.fetch(:status)
        end

        def normalized_invitation_status(user, requested_status)
          requested = requested_status.presence || user.invitation_status
          return user.invitation_status unless requested.in?(User::INVITATION_STATUSES)
          return "revoked" if requested == "revoked"

          linked_to_clerk?(user) ? "accepted" : "pending"
        end

        def linked_to_clerk?(user)
          user.clerk_id.present? && !user.clerk_id.start_with?("pending_")
        end

        def cohort_membership_params_present?
          user_payload = params[:user]
          return false unless user_payload.respond_to?(:key?)

          user_payload.key?(:cohort_id) || user_payload.key?(:cohort_ids)
        end

        def cohort_ids_from_params
          raw_ids = Array(params.dig(:user, :cohort_ids))
          raw_ids << params.dig(:user, :cohort_id)
          ids = raw_ids.filter_map { |value| value.to_s.presence }.map(&:to_i).uniq
          return [] if ids.empty?

          cohorts = Cohort.where(id: ids).to_a
          missing_ids = ids - cohorts.map(&:id)
          raise ActiveRecord::RecordNotFound, "Cohort not found: #{missing_ids.join(', ')}" if missing_ids.any?

          ids
        end

        def sync_cohort_memberships(user, cohort_ids, role:)
          user.cohort_memberships.where.not(cohort_id: cohort_ids).destroy_all
          cohort_ids.each do |cohort_id|
            membership = user.cohort_memberships.find_or_initialize_by(cohort_id: cohort_id)
            membership.update!(role: role)
          end
        end

        def cohort_role_for(user_role)
          return "admin" if user_role == "admin"
          return "coach" if user_role == "coach"

          "participant"
        end

        def pending_clerk_id
          "pending_#{SecureRandom.hex(12)}"
        end

        def bounded_text(value, max_length)
          return nil if value.nil?

          value.to_s.squish.truncate(max_length, omission: "…")
        end

        def serialize_user(user)
          household = user.household_memberships.sort_by(&:created_at).first&.household
          snapshot = household ? HouseholdFinance::SnapshotBuilder.new(household).call : nil

          user.as_api_json.merge(
            invited_by: serialize_inviter(user.invited_by_user),
            cohorts: user.cohort_memberships.sort_by { |membership| membership.cohort.name.downcase }.map { |membership| serialize_membership(membership) },
            workspace: {
              household_id: household&.id,
              household_name: household&.name,
              setup_complete: snapshot ? snapshot.fetch(:profile_completeness) >= 70 : false,
              profile_completeness: snapshot ? snapshot.fetch(:profile_completeness) : 0,
              readiness_label: snapshot ? snapshot.fetch(:readiness_label) : "Not started"
            }
          )
        end

        def serialize_inviter(inviter)
          return nil unless inviter

          {
            id: inviter.id,
            email: inviter.email,
            full_name: inviter.full_name
          }
        end

        def serialize_membership(membership)
          {
            id: membership.id,
            role: membership.role,
            cohort: {
              id: membership.cohort.id,
              name: membership.cohort.name,
              status: membership.cohort.status
            }
          }
        end
      end
    end
  end
end
