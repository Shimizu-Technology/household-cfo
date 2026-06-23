module Api
  module V1
    module Admin
      class UsersController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!

        def index
          render json: { users: users_scope.map { |user| serialize_user(user) } }
        end

        def create
          attributes = user_params
          role = attributes[:role].presence || "participant"
          return render json: { errors: [ "Role is not valid" ] }, status: :unprocessable_entity unless User::ROLES.include?(role)
          return render_forbidden("Role assignment not permitted") unless role_assignable_by_current_user?(role)

          cohort_ids = cohort_ids_from_attributes(attributes)
          return render_cohort_required(role) if cohort_required?(role) && cohort_ids.empty?
          return render_forbidden("Cohort assignment not permitted") unless cohort_assignment_permitted?(cohort_ids)

          user = nil
          User.transaction do
            user = User.create!(
              email: attributes[:email],
              first_name: bounded_text(attributes[:first_name], 80),
              last_name: bounded_text(attributes[:last_name], 80),
              role: role,
              clerk_id: pending_clerk_id,
              invitation_status: "pending",
              invited_at: Time.current,
              invited_by_user: current_user
            )
            sync_cohort_memberships(user, cohort_ids, role: cohort_role_for(role))
          end

          invitation_result = send_invitation_email(user)
          render json: invite_response_payload(user.reload, invitation_result), status: :created
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
          return render_forbidden("Status update not permitted") if attributes.key?(:invitation_status) && !current_user.admin?
          if attributes[:invitation_status].present? && !User::INVITATION_STATUSES.include?(attributes[:invitation_status])
            return render json: { errors: [ "Invitation status is not valid" ] }, status: :unprocessable_entity
          end
          return render_forbidden("User update not permitted") unless user_update_permitted_by_current_user?(user, role)

          membership_params_present = cohort_membership_params_present?(attributes)
          cohort_ids = membership_params_present ? cohort_ids_from_attributes(attributes) : user.cohort_memberships.pluck(:cohort_id)
          return render_cohort_required(role) if cohort_required?(role) && cohort_ids.empty?
          return render_forbidden("Cohort assignment not permitted") if membership_params_present && !cohort_assignment_permitted?(cohort_ids)

          admin_guard_error = nil
          User.transaction do
            user.lock!
            role = attributes[:role].presence || user.role
            normalized_status = normalized_invitation_status(user, attributes[:invitation_status])
            if active_admin_access_removal?(user, role:, invitation_status: normalized_status)
              admin_guard_error = admin_change_error(user, locked_admin_ids: locked_active_admin_ids)
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

            if membership_params_present
              sync_cohort_memberships(user, cohort_ids, role: cohort_role_for(user.role))
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

        def resend_invitation
          user = User.find(params[:id])
          return render_forbidden("User update not permitted") unless user_update_permitted_by_current_user?(user, user.role)
          return render json: { errors: [ "Accepted users do not need another invitation" ] }, status: :unprocessable_entity if user.invitation_accepted?
          return render json: { errors: [ "Reactivate this user before resending an invitation" ] }, status: :unprocessable_entity if user.revoked?

          result = send_invitation_email(user)
          render json: invite_response_payload(user.reload, result)
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotFound => e
          render json: { errors: [ e.message ] }, status: :unprocessable_entity
        end

        private

        def users_scope
          scope = User.includes(
            :invited_by_user,
            :last_invite_email_sent_by_user,
            invitation_email_attempts: :sent_by_user,
            cohort_memberships: :cohort,
            household_memberships: { household: %i[income_sources expense_items debts accounts goals] }
          )
          unless current_user.admin?
            scope = scope.joins(:cohort_memberships)
              .where(role: "participant", cohort_memberships: { cohort_id: coach_cohort_ids })
              .distinct
          end

          scope.order(:email)
        end

        def user_params
          params.require(:user)
            .permit(:email, :first_name, :last_name, :role, :cohort_id, cohort_ids: [])
            .to_h
            .symbolize_keys
        end

        def user_update_params
          params.require(:user)
            .permit(:first_name, :last_name, :role, :invitation_status, :cohort_id, cohort_ids: [])
            .to_h
            .symbolize_keys
            .compact
        end

        def role_assignable_by_current_user?(role)
          return true if current_user.admin?

          current_user.coach? && role == "participant"
        end

        def user_update_permitted_by_current_user?(user, requested_role)
          return true if current_user.admin?

          current_user.coach? && user.participant? && requested_role == "participant" && user_visible_to_current_coach?(user)
        end

        def user_visible_to_current_coach?(user)
          (user.cohort_memberships.pluck(:cohort_id) & coach_cohort_ids).any?
        end

        def cohort_assignment_permitted?(cohort_ids)
          return true if current_user.admin?

          cohort_ids.present? && (cohort_ids - coach_cohort_ids).empty?
        end

        def coach_cohort_ids
          @coach_cohort_ids ||= current_user.cohort_memberships.pluck(:cohort_id)
        end

        def active_admin_access_removal?(user, role:, invitation_status:)
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

        def cohort_membership_params_present?(attributes)
          attributes.key?(:cohort_id) || attributes.key?(:cohort_ids)
        end

        def cohort_ids_from_attributes(attributes)
          raw_ids = Array(attributes[:cohort_ids])
          raw_ids << attributes[:cohort_id]
          ids = raw_ids.filter_map { |value| value.to_s.presence }.map(&:to_i).uniq
          return [] if ids.empty?

          cohorts = Cohort.where(id: ids).to_a
          missing_ids = ids - cohorts.map(&:id)
          raise ActiveRecord::RecordNotFound, "Cohort not found: #{missing_ids.join(', ')}" if missing_ids.any?

          ids
        end

        def cohort_required?(role)
          role != "admin"
        end

        def render_cohort_required(role)
          render json: { errors: [ "#{role.titleize} users must be assigned to at least one cohort" ] }, status: :unprocessable_entity
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

        def send_invitation_email(user)
          result = UserInviteEmailService.send_invite(user: user, invited_by: current_user)
          record_invitation_email_attempt(user, result)
          result
        end

        def record_invitation_email_attempt(user, result)
          attempted_at = Time.current
          sent_at = result[:sent] ? attempted_at : nil

          user.with_lock do
            attempt = user.invitation_email_attempts.create!(
              status: result.fetch(:status),
              provider: "resend",
              provider_message_id: result[:provider_message_id],
              error: result[:error],
              attempted_at: attempted_at,
              sent_at: sent_at,
              sent_by_user: current_user
            )
            user.update!(invitation_email_summary_attributes(user, attempt))
          end
        end

        def invitation_email_summary_attributes(user, attempt)
          {
            invited_at: user.invited_at || attempt.attempted_at,
            invited_by_user: user.invited_by_user || current_user,
            invitation_email_status: attempt.status,
            invitation_email_provider_id: attempt.provider_message_id,
            invitation_email_error: attempt.error,
            last_invite_email_attempted_at: attempt.attempted_at,
            last_invite_email_sent_at: attempt.sent_at || user.last_invite_email_sent_at,
            last_invite_email_sent_by_user: attempt.status == "sent" ? current_user : user.last_invite_email_sent_by_user
          }
        end

        def invite_response_payload(user, result)
          {
            user: serialize_user(user),
            invitation_sent: result[:sent],
            invitation_status: result[:status],
            invitation_error: result[:error]
          }
        end

        def serialize_user(user)
          household = user.household_memberships.sort_by(&:created_at).first&.household
          snapshot = household ? HouseholdFinance::SnapshotBuilder.new(household).call : nil

          user.as_api_json.merge(
            invited_by: serialize_inviter(user.invited_by_user),
            invite_email: serialize_invite_email(user),
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

        def serialize_invite_email(user)
          {
            status: user.invitation_email_status.presence || "not_sent",
            provider_message_id: user.invitation_email_provider_id,
            error: user.invitation_email_error,
            last_attempted_at: user.last_invite_email_attempted_at,
            last_sent_at: user.last_invite_email_sent_at,
            last_sent_by: serialize_inviter(user.last_invite_email_sent_by_user),
            delivery_log: serialized_invitation_email_attempts(user)
          }
        end

        def serialized_invitation_email_attempts(user)
          user.invitation_email_attempts
            .sort_by { |attempt| [ attempt.attempted_at, attempt.id ] }
            .last(5)
            .map { |attempt| serialize_invitation_email_attempt(attempt) }
        end

        def serialize_invitation_email_attempt(attempt)
          {
            id: attempt.id,
            status: attempt.status,
            attempted_at: attempt.attempted_at,
            sent_at: attempt.sent_at,
            sent_by_user_id: attempt.sent_by_user_id,
            sent_by: serialize_inviter(attempt.sent_by_user),
            provider: attempt.provider,
            provider_message_id: attempt.provider_message_id,
            error: attempt.error
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
