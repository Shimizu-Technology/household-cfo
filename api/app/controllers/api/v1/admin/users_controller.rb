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
          role = user_update_params[:role].presence || user.role
          return render json: { errors: [ "Role is not valid" ] }, status: :unprocessable_entity unless User::ROLES.include?(role)
          return render_forbidden("User update not permitted") unless user_update_permitted_by_current_user?(user, role)

          normalized_status = normalized_invitation_status(user, user_update_params[:invitation_status])
          ensure_admin_can_change!(user, role:, invitation_status: normalized_status)
          return if performed?

          User.transaction do
            update_attributes = {
              role: role,
              invitation_status: normalized_status
            }
            update_attributes[:first_name] = bounded_text(user_update_params[:first_name], 80) if user_update_params.key?(:first_name)
            update_attributes[:last_name] = bounded_text(user_update_params[:last_name], 80) if user_update_params.key?(:last_name)
            user.assign_attributes(update_attributes)
            user.invited_at ||= Time.current if user.invitation_status == "pending"
            user.save!

            if cohort_membership_params_present?
              sync_cohort_memberships(user, cohort_ids_from_params, role: cohort_role_for(user.role))
            else
              user.cohort_memberships.update_all(role: cohort_role_for(user.role), updated_at: Time.current)
            end
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
          {
            email: payload[:email],
            first_name: payload[:first_name],
            last_name: payload[:last_name],
            role: payload[:role],
            cohort_id: payload[:cohort_id],
            cohort_ids: payload[:cohort_ids]
          }
        end

        def user_update_params
          payload = params.require(:user)
          {
            first_name: payload[:first_name],
            last_name: payload[:last_name],
            role: payload[:role],
            invitation_status: payload[:invitation_status],
            cohort_id: payload[:cohort_id],
            cohort_ids: payload[:cohort_ids]
          }.compact
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

        def ensure_admin_can_change!(user, role:, invitation_status:)
          return unless user.admin? && (role != "admin" || invitation_status == "revoked")

          return render_forbidden("You cannot remove your own admin access") if user == current_user
          return unless active_admin_count(excluding: user) <= 0

          render json: { errors: [ "At least one active admin is required" ] }, status: :unprocessable_entity
        end

        def active_admin_count(excluding: nil)
          scope = User.where(role: "admin").where.not(invitation_status: "revoked")
          scope = scope.where.not(id: excluding.id) if excluding
          scope.count
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
