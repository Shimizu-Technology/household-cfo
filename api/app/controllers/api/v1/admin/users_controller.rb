module Api
  module V1
    module Admin
      class UsersController < BaseController
        InvitationMembershipLockSetChanged = Class.new(StandardError)

        before_action :authenticate_user!
        before_action :require_staff!
        before_action :require_participant_management!
        rescue_from Mia::PersonaAssignmentCompatibility::Conflict, with: :render_persona_membership_conflict

        def index
          users = users_scope.to_a
          preload_recent_invitation_email_attempts(users) unless workspace_scoped_mode?
          progress_by_user_id = HouseholdFinance::PilotProgressBatchBuilder.new(users).call
          render json: {
            users: users.map do |user|
              serialize_user(user, pilot_progress: progress_by_user_id.fetch(user.id))
            end
          }
        end

        def create
          attributes = user_params
          role = attributes[:role].presence || "participant"
          return render json: { errors: [ "Role is not valid" ] }, status: :unprocessable_entity unless User::ROLES.include?(role)
          return render_forbidden("Role assignment not permitted") unless role_assignable_by_current_user?(role)

          cohort_ids = cohort_ids_from_attributes(attributes)
          return render_cohort_required(role) if cohort_required?(role) && cohort_ids.empty?
          return render_forbidden("Cohort assignment not permitted") unless cohort_assignment_permitted?(cohort_ids)

          email = normalized_email(attributes[:email])
          existing_user = User.find_by("LOWER(email) = ?", email) if email.present?
          if existing_user
            create_or_reactivate_existing_user(existing_user, attributes:, role:, cohort_ids:)
          else
            create_new_invited_user(attributes:, role:, cohort_ids:)
          end
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotFound => e
          render json: { errors: [ e.message ] }, status: :unprocessable_entity
        end

        def update
          user = manageable_users_scope.find(params[:id])
          attributes = user_update_params
          role = attributes[:role].presence || user.role
          return render json: { errors: [ "Role is not valid" ] }, status: :unprocessable_entity unless User::ROLES.include?(role)
          return render_forbidden("User update not permitted") unless user_update_permitted_by_current_user?(user, role)
          if workspace_scoped_mode? && user_shared_outside_active_workspace?(user) && global_user_change_requested?(user, attributes, role: role)
            return render_forbidden("Switch to All workspaces / Platform to change this shared user's identity or account access")
          end
          return render_forbidden("Status update not permitted") if attributes.key?(:invitation_status) && !current_user.admin?
          if attributes[:invitation_status].present? && !User::INVITATION_STATUSES.include?(attributes[:invitation_status])
            return render json: { errors: [ "Invitation status is not valid" ] }, status: :unprocessable_entity
          end
          requested_invitation_status = normalized_invitation_status(user, attributes[:invitation_status])
          membership_params_present = cohort_membership_params_present?(attributes)
          cohort_ids = if membership_params_present
            cohort_ids_from_attributes(attributes)
          elsif workspace_scoped_mode?
            user.cohort_memberships.where(cohort_id: manageable_cohort_ids_for_request).pluck(:cohort_id)
          else
            user.cohort_memberships.pluck(:cohort_id)
          end
          requirement_cohort_ids = cohort_ids
          if workspace_scoped_mode?
            requirement_cohort_ids |= user.cohort_memberships.where.not(cohort_id: manageable_cohort_ids_for_request).pluck(:cohort_id)
          end
          return render_cohort_required(role) if cohort_required?(role, requested_invitation_status) && requirement_cohort_ids.empty?
          return render_forbidden("Cohort assignment not permitted") if membership_params_present && !cohort_assignment_permitted?(cohort_ids)

          admin_guard_error = nil
          workspace_guard_error = nil
          owner_guard_error = nil
          apply_update = lambda do |compatibility_cohort_ids, locked_admin_ids|
            role = attributes[:role].presence || user.role
            normalized_status = normalized_invitation_status(user, attributes[:invitation_status])
            if workspace_scoped_mode? && user_shared_outside_active_workspace?(user) && global_user_change_requested?(user, attributes, role: role)
              workspace_guard_error = "Switch to All workspaces / Platform to change this shared user's identity or account access"
              raise ActiveRecord::Rollback
            end
            if active_admin_access_removal?(user, role:, invitation_status: normalized_status)
              locked_admin_ids ||= locked_active_admin_ids
              admin_guard_error = admin_change_error(user, locked_admin_ids: locked_admin_ids)
              raise ActiveRecord::Rollback if admin_guard_error
            end

            owner_guard_error = owner_access_change_error(user, role: role, invitation_status: normalized_status)
            raise ActiveRecord::Rollback if owner_guard_error

            update_attributes = {
              role: role,
              invitation_status: normalized_status
            }
            update_attributes[:first_name] = bounded_text(attributes[:first_name], 80) if attributes.key?(:first_name)
            update_attributes[:last_name] = bounded_text(attributes[:last_name], 80) if attributes.key?(:last_name)
            user.assign_attributes(update_attributes)
            user.invited_at ||= Time.current if user.invitation_status == "pending"
            user.save!

            if user.participant?
              user.coach_workspace_memberships.find_each do |workspace_membership|
                CoachWorkspaceMembershipEvent.create!(coach_workspace_id: workspace_membership.coach_workspace_id,
                  actor_user: current_user, subject_user: user, event_type: "removed", before_role: workspace_membership.role)
                workspace_membership.destroy!
              end
            end

            if membership_params_present
              sync_cohort_memberships_for_request(
                user,
                cohort_ids,
                role: cohort_role_for(user.role),
                compatibility_cohort_ids: compatibility_cohort_ids
              )
            else
              if cohort_role_for(user.role) == "participant"
                Mia::PersonaAssignmentCompatibility.ensure_participant_can_join!(cohort_ids: compatibility_cohort_ids)
              end
              membership_scope = user.cohort_memberships
              membership_scope = membership_scope.where(cohort_id: manageable_cohort_ids_for_request) if workspace_scoped_mode?
              membership_scope.find_each { |membership| membership.update!(role: cohort_role_for(user.role)) }
            end
          end
          if workspace_scoped_mode? && membership_params_present && cohort_role_for(role) == "participant"
            before_user_lock = -> { requested_admin_access_removal?(attributes) ? locked_active_admin_ids : nil }
            with_stable_scoped_membership_locks(
              user,
              requested_cohort_ids: cohort_ids,
              before_user_lock: before_user_lock,
              &apply_update
            )
          else
            before_user_lock = -> { requested_admin_access_removal?(attributes) ? locked_active_admin_ids : nil }
            with_stable_membership_locks(user, target_cohort_ids: -> { cohort_ids }, before_user_lock: before_user_lock, &apply_update)
          end

          if admin_guard_error
            render_admin_guard_error(admin_guard_error)
            return
          end
          return render_forbidden(workspace_guard_error) if workspace_guard_error
          if owner_guard_error
            return render json: { errors: [ owner_guard_error ], code: "workspace_owner_handover_required" }, status: :unprocessable_entity
          end

          render json: { user: serialize_user(user.reload) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotFound => e
          render json: { errors: [ e.message ] }, status: :unprocessable_entity
        end

        def resend_invitation
          user = manageable_users_scope.find(params[:id])
          return render_forbidden("User update not permitted") unless user_update_permitted_by_current_user?(user, user.role)

          guard_error = nil
          result = nil
          User.transaction do
            user.lock!
            guard_error = if workspace_scoped_mode? && user_shared_outside_active_workspace?(user)
              "Switch to All workspaces / Platform to resend an invitation for this shared user"
            elsif user.invitation_accepted?
              "Accepted users do not need another invitation"
            elsif user.revoked?
              "Reactivate this user before resending an invitation"
            end
            if guard_error
              raise ActiveRecord::Rollback
            else
              result = send_invitation_email(user)
            end
          end
          if guard_error
            return render_forbidden(guard_error) if guard_error.start_with?("Switch")

            return render json: { errors: [ guard_error ] }, status: :unprocessable_entity
          end
          render json: invite_response_payload(user.reload, result)
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotFound => e
          render json: { errors: [ e.message ] }, status: :unprocessable_entity
        end

        private

        def create_new_invited_user(attributes:, role:, cohort_ids:)
          user = nil
          User.transaction do
            lock_cohorts!(cohort_ids)
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

          invitation_result = send_invitation_email(user, requested: invitation_email_requested?(attributes))
          render json: invite_response_payload(user.reload, invitation_result, created: true, reactivated: false), status: :created
        end

        def create_or_reactivate_existing_user(user, attributes:, role:, cohort_ids:)
          return render_forbidden("User update not permitted") unless user_update_permitted_by_current_user?(user, role)
          if workspace_scoped_mode? && user_shared_outside_active_workspace?(user)
            if user.revoked? || global_user_change_requested?(user, attributes, role: role)
              return render_forbidden("Switch to All workspaces / Platform to reactivate or change this shared user")
            end

            workspace_guard_error = nil
            with_stable_invitation_membership_locks(
              user,
              requested_cohort_ids: cohort_ids,
              replace_memberships: false
            ) do |compatibility_cohort_ids|
              workspace_guard_error = shared_user_attach_guard_error(user, attributes:, role:)
              raise ActiveRecord::Rollback if workspace_guard_error

              if cohort_role_for(role) == "participant"
                Mia::PersonaAssignmentCompatibility.ensure_participant_can_join!(cohort_ids: compatibility_cohort_ids)
              end
              add_cohort_memberships(user, cohort_ids, role: cohort_role_for(role))
            end
            return render_forbidden(workspace_guard_error) if workspace_guard_error

            return render json: invite_response_payload(
              user.reload,
              { sent: false, status: "skipped", error: "Existing shared user attached without changing the global account" },
              created: false,
              reactivated: false
            ), status: :ok
          end
          unless user.revoked? || user.role == role
            return render json: { errors: [ "This email already belongs to an existing #{user.role} user. Update the existing user row to change role." ] }, status: :unprocessable_entity
          end

          was_revoked = user.revoked?
          target_status = linked_to_clerk?(user) ? "accepted" : "pending"
          workspace_guard_error = nil
          with_stable_invitation_membership_locks(
            user,
            requested_cohort_ids: cohort_ids,
            replace_memberships: was_revoked
          ) do |target_cohort_ids|
            # This is the normal invitation/reactivation path. A user that was
            # already shared took the attach-only path above. If another
            # workspace attached the user while this request waited for its
            # stable locks, fail closed before changing global invite state.
            if workspace_scoped_mode? && user_shared_outside_active_workspace?(user)
              workspace_guard_error = "Switch to All workspaces / Platform because this user is now shared across workspaces"
              raise ActiveRecord::Rollback
            end
            user.assign_attributes(
              role: role,
              invitation_status: target_status,
              invited_at: Time.current,
              invited_by_user: current_user
            )
            user.first_name = bounded_text(attributes[:first_name], 80) if attributes[:first_name].present?
            user.last_name = bounded_text(attributes[:last_name], 80) if attributes[:last_name].present?
            user.accepted_at ||= Time.current if target_status == "accepted"
            user.save!
            sync_cohort_memberships(user, target_cohort_ids, role: cohort_role_for(role))
          end
          return render_forbidden(workspace_guard_error) if workspace_guard_error

          invitation_result = send_invitation_email(user, requested: invitation_email_requested?(attributes))
          render json: invite_response_payload(user.reload, invitation_result, created: false, reactivated: was_revoked), status: :ok
        end

        def shared_user_attach_guard_error(user, attributes:, role:)
          unless user_update_permitted_by_current_user?(user, role)
            return "User update not permitted"
          end
          unless user_shared_outside_active_workspace?(user)
            return "This shared user changed while the request was waiting. Reload and try again."
          end
          if user.revoked? || global_user_change_requested?(user, attributes, role: role)
            return "Switch to All workspaces / Platform to reactivate or change this shared user"
          end

          nil
        end

        def users_scope
          scope = User.includes(
            :invited_by_user,
            :last_invite_email_sent_by_user,
            :coach_workspace_memberships,
            cohort_memberships: :cohort
          )
          if current_user.admin?
            scope = scope.where(id: selected_workspace_user_ids) if coach_workspace_for_policy
          else
            scope = scope.joins(:cohort_memberships)
              .where(role: "participant", cohort_memberships: { cohort_id: coach_cohort_ids })
              .distinct
          end

          scope.order(:email)
        end

        def manageable_users_scope
          return User.all unless current_user.admin? && coach_workspace_for_policy

          User.where(id: selected_workspace_user_ids)
        end

        def selected_workspace_user_ids
          @selected_workspace_user_ids ||= begin
            cohort_user_ids = CohortMembership.where(cohort_id: current_workspace_cohort_ids).select(:user_id)
            workspace_user_ids = CoachWorkspaceMembership.where(coach_workspace: coach_workspace_for_policy).select(:user_id)
            User.where(id: cohort_user_ids).or(User.where(id: workspace_user_ids)).select(:id)
          end
        end

        def workspace_scoped_mode?
          coach_workspace_for_policy.present?
        end

        def user_shared_outside_active_workspace?(user)
          return false unless workspace_scoped_mode?

          (user_workspace_ids(user) - [ coach_workspace_for_policy.id ]).any?
        end

        def user_workspace_ids(user)
          cohort_workspace_ids = Cohort.joins(:cohort_memberships)
            .where(cohort_memberships: { user_id: user.id })
            .distinct
            .pluck(:coach_workspace_id)
          membership_workspace_ids = user.coach_workspace_memberships.pluck(:coach_workspace_id)
          (cohort_workspace_ids | membership_workspace_ids).compact
        end

        def global_user_change_requested?(user, attributes, role:)
          return true if role != user.role
          return true if attributes.key?(:invitation_status) && normalized_invitation_status(user, attributes[:invitation_status]) != user.invitation_status
          return true if attributes.key?(:first_name) && bounded_text(attributes[:first_name], 80) != user.first_name
          return true if attributes.key?(:last_name) && bounded_text(attributes[:last_name], 80) != user.last_name

          false
        end

        def user_params
          params.require(:user)
            .permit(:email, :first_name, :last_name, :role, :cohort_id, :send_invitation_email, cohort_ids: [])
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
          return (cohort_ids - current_workspace_cohort_ids).empty? if current_user.admin?

          (cohort_ids - coach_cohort_ids).empty?
        end

        def require_participant_management!
          render_forbidden("Participant management access required") unless participant_roster_policy.manage?
        end

        def participant_roster_policy
          @participant_roster_policy ||= CoachWorkspaces::ParticipantRosterPolicy.new(
            user: current_user, workspace: coach_workspace_for_policy
          )
        end

        def coach_cohort_ids
          @coach_cohort_ids ||= participant_roster_policy.cohort_ids
        end

        def current_workspace_cohort_ids
          @current_workspace_cohort_ids ||= coach_workspace_for_policy ? Cohort.where(coach_workspace: coach_workspace_for_policy).pluck(:id) : Cohort.pluck(:id)
        end

        def manageable_cohort_ids_for_request
          @manageable_cohort_ids_for_request ||= current_user.admin? ? current_workspace_cohort_ids : coach_cohort_ids
        end

        def requested_admin_access_removal?(attributes)
          (attributes[:role].present? && attributes[:role] != "admin") || attributes[:invitation_status] == "revoked"
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

        def cohort_required?(role, invitation_status = "pending")
          role != "admin" && invitation_status != "revoked"
        end

        def render_cohort_required(role)
          render json: { errors: [ "#{role.titleize} users must be assigned to at least one cohort" ] }, status: :unprocessable_entity
        end

        def sync_cohort_memberships(user, cohort_ids, role:)
          if role == "participant"
            Mia::PersonaAssignmentCompatibility.lock_participants!(user_ids: [ user.id ])
            Mia::PersonaAssignmentCompatibility.ensure_participant_can_join!(cohort_ids: cohort_ids)
          end
          user.cohort_memberships.where.not(cohort_id: cohort_ids).destroy_all
          cohort_ids.each do |cohort_id|
            membership = user.cohort_memberships.find_or_initialize_by(cohort_id: cohort_id)
            membership.update!(role: role)
          end
        end

        def sync_cohort_memberships_for_request(user, cohort_ids, role:, compatibility_cohort_ids: cohort_ids)
          return sync_cohort_memberships(user, cohort_ids, role: role) unless workspace_scoped_mode?

          if role == "participant"
            Mia::PersonaAssignmentCompatibility.lock_participants!(user_ids: [ user.id ])
            Mia::PersonaAssignmentCompatibility.ensure_participant_can_join!(cohort_ids: compatibility_cohort_ids)
          end
          user.cohort_memberships.where(cohort_id: manageable_cohort_ids_for_request).where.not(cohort_id: cohort_ids).destroy_all
          add_cohort_memberships(user, cohort_ids, role: role)
        end

        def add_cohort_memberships(user, cohort_ids, role:)
          cohort_ids.each do |cohort_id|
            membership = user.cohort_memberships.find_or_initialize_by(cohort_id: cohort_id)
            membership.update!(role: role)
          end
        end

        def with_stable_invitation_membership_locks(user, requested_cohort_ids:, replace_memberships:, &block)
          target_cohort_ids = lambda do
            invitation_target_cohort_ids(
              user,
              requested_cohort_ids: requested_cohort_ids,
              replace_memberships: replace_memberships
            )
          end
          with_stable_membership_locks(user, target_cohort_ids:, &block)
        end

        def with_stable_scoped_membership_locks(user, requested_cohort_ids:, before_user_lock: nil, &block)
          target_cohort_ids = lambda do
            retained_ids = CohortMembership.where(user_id: user.id)
              .where.not(cohort_id: manageable_cohort_ids_for_request)
              .pluck(:cohort_id)
            retained_ids | Array(requested_cohort_ids).map(&:to_i).uniq
          end
          with_stable_membership_locks(user, target_cohort_ids:, before_user_lock:, &block)
        end

        def with_stable_membership_locks(user, target_cohort_ids:, before_user_lock: nil)
          locked_cohort_ids = target_cohort_ids.call
          locked_workspace_ids = membership_workspace_ids(user)

          loop do
            retry_cohort_ids = nil
            retry_workspace_ids = nil
            begin
              User.transaction do
                lock_cohorts!(locked_cohort_ids)
                CoachWorkspace.where(id: locked_workspace_ids).order(:id).lock.load
                lock_context = before_user_lock&.call
                user.lock!
                current_target_cohort_ids = target_cohort_ids.call
                current_workspace_ids = membership_workspace_ids(user)

                if current_target_cohort_ids.sort != locked_cohort_ids.sort || current_workspace_ids != locked_workspace_ids
                  retry_cohort_ids = current_target_cohort_ids
                  retry_workspace_ids = current_workspace_ids
                  raise InvitationMembershipLockSetChanged
                end

                yield current_target_cohort_ids, lock_context
              end
              return
            rescue InvitationMembershipLockSetChanged
              locked_cohort_ids = retry_cohort_ids
              locked_workspace_ids = retry_workspace_ids
            end
          end
        end

        def membership_workspace_ids(user)
          CoachWorkspaceMembership.where(user_id: user.id).order(:coach_workspace_id).pluck(:coach_workspace_id)
        end

        def owner_access_change_error(user, role:, invitation_status:)
          return unless user.invitation_accepted? && (!role.in?(%w[coach admin]) || invitation_status != "accepted")

          CoachWorkspaceMembership.where(user_id: user.id, role: "owner").order(:coach_workspace_id).pluck(:coach_workspace_id).each do |workspace_id|
            available_owner = CoachWorkspaceMembership.joins(:user).where(coach_workspace_id: workspace_id, role: "owner", users: { role: %w[coach admin], invitation_status: "accepted" })
              .where.not(user_id: user.id).where.not("users.clerk_id LIKE ?", "pending_%").exists?
            return "Assign another active owner in every owned workspace before changing this account's access." unless available_owner
          end
          nil
        end

        def invitation_target_cohort_ids(user, requested_cohort_ids:, replace_memberships:)
          requested_ids = Array(requested_cohort_ids).map(&:to_i).uniq
          return requested_ids if replace_memberships

          existing_ids = CohortMembership.where(user_id: user.id).pluck(:cohort_id)
          existing_ids | requested_ids
        end

        def lock_cohorts!(cohort_ids)
          ids = Array(cohort_ids).map(&:to_i).uniq.sort
          Cohort.where(id: ids).order(:id).lock.load if ids.any?
        end

        def render_persona_membership_conflict(error)
          render json: { error: error.message, code: "persona_assignment_conflict" }, status: :conflict
        end

        def cohort_role_for(user_role)
          return "admin" if user_role == "admin"
          return "coach" if user_role == "coach"

          "participant"
        end

        def pending_clerk_id
          "pending_#{SecureRandom.hex(12)}"
        end

        def normalized_email(value)
          value.to_s.strip.downcase
        end

        def bounded_text(value, max_length)
          return nil if value.nil?

          value.to_s.squish.truncate(max_length, omission: "…")
        end

        def invitation_email_requested?(attributes)
          return true unless attributes.key?(:send_invitation_email)

          ActiveModel::Type::Boolean.new.cast(attributes[:send_invitation_email])
        end

        def send_invitation_email(user, requested: true)
          result = requested ? UserInviteEmailService.send_invite(user: user, invited_by: current_user) : skipped_invitation_email_result
          record_invitation_email_attempt(user, result)
          result
        rescue ActiveRecord::ActiveRecordError => e
          Rails.logger.error("[InviteEmail] Audit recording failed for #{user.email}: #{e.class} #{e.message}")
          fallback_result = audit_recording_failure_result(result, e)
          record_invitation_email_summary_after_audit_failure(user, fallback_result)
          fallback_result
        end

        def skipped_invitation_email_result
          Rails.logger.info("[InviteEmail] Invite email skipped by admin for #{params.dig(:user, :email)}")
          {
            sent: false,
            status: "skipped",
            provider_message_id: nil,
            error: "Email delivery skipped by admin"
          }
        end

        def audit_recording_failure_result(result, error)
          delivered = result&.fetch(:sent, false) == true
          original_error = result&.fetch(:error, nil)
          audit_error = "delivery audit could not be recorded: #{error.message}"
          {
            sent: delivered,
            status: delivered ? "sent" : "failed",
            provider_message_id: result&.fetch(:provider_message_id, nil),
            error: [ original_error, audit_error ].compact_blank.join("; ")
          }
        end

        def record_invitation_email_summary_after_audit_failure(user, fallback_result)
          attempted_at = Time.current
          user.with_lock do
            user.update!(
              invited_at: user.invited_at || attempted_at,
              invited_by_user: user.invited_by_user || current_user,
              invitation_email_status: fallback_result.fetch(:status),
              invitation_email_provider_id: fallback_result[:provider_message_id],
              invitation_email_error: fallback_result[:error],
              last_invite_email_attempted_at: attempted_at,
              last_invite_email_sent_at: fallback_result[:sent] ? attempted_at : user.last_invite_email_sent_at,
              last_invite_email_sent_by_user: fallback_result[:sent] ? current_user : user.last_invite_email_sent_by_user
            )
          end
        rescue ActiveRecord::ActiveRecordError => e
          Rails.logger.error("[InviteEmail] Summary fallback failed for #{user.email}: #{e.class} #{e.message}")
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

        def invite_response_payload(user, result, created: nil, reactivated: nil)
          {
            user: serialize_user(user),
            created: created,
            reactivated: reactivated,
            invitation_sent: result[:sent],
            invitation_status: result[:status],
            invitation_error: result[:error]
          }
        end

        def serialize_user(user, pilot_progress: nil)
          progress = pilot_progress || begin
            household = user.household_memberships.order(:created_at, :id).first&.household
            HouseholdFinance::PilotProgressBuilder.new(user, household: household).call
          end

          serialized_user_identity(user).merge(
            invited_by: workspace_scoped_mode? ? nil : serialize_inviter(user.invited_by_user),
            invite_email: serialize_invite_email(user),
            cohorts: serialized_memberships(user),
            workspace: progress
          )
        end

        def serialized_user_identity(user)
          return user.as_api_json unless workspace_scoped_mode?

          payload = {
            id: user.id,
            clerk_id: user.clerk_id,
            email: user.email,
            first_name: user.first_name,
            last_name: user.last_name,
            full_name: user.full_name,
            role: user.role,
            invitation_status: user.invitation_status,
            invited_at: user.invited_at,
            accepted_at: user.accepted_at,
            last_sign_in_at: user.last_sign_in_at,
            created_at: user.created_at,
            is_admin: user.admin?,
            is_coach: user.coach?,
            is_participant: user.participant?,
            is_staff: user.staff?
          }
          return payload unless user.staff?

          membership = user.coach_workspace_memberships.find do |candidate|
            candidate.coach_workspace_id == coach_workspace_for_policy.id
          end
          workspace_visible = user.admin? || membership.present?
          workspace = workspace_visible ? serialized_active_workspace(user:, membership:) : nil
          payload.merge(
            coach_workspaces: workspace ? [ workspace ] : [],
            active_coach_workspace: workspace
          )
        end

        def serialized_active_workspace(user:, membership:)
          workspace = coach_workspace_for_policy
          profile = workspace.coach_profile
          {
            id: workspace.id,
            name: workspace.name,
            slug: workspace.slug,
            membership_role: user.admin? ? "platform_admin" : membership&.role,
            coach_profile: profile && {
              display_name: profile.display_name,
              title: profile.title,
              bio: profile.bio.to_s
            }
          }
        end

        def serialized_memberships(user)
          memberships = user.cohort_memberships
          memberships = memberships.select { |membership| membership.cohort_id.in?(current_workspace_cohort_ids) } if workspace_scoped_mode?
          memberships.sort_by { |membership| membership.cohort.name.downcase }.map { |membership| serialize_membership(membership) }
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
          if workspace_scoped_mode?
            return {
              status: "hidden",
              provider_message_id: nil,
              error: nil,
              last_attempted_at: nil,
              last_sent_at: nil,
              last_sent_by: nil,
              delivery_log: [],
              workspace_scoped: true
            }
          end

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
          recent_invitation_email_attempts_for(user).map { |attempt| serialize_invitation_email_attempt(attempt) }
        end

        def recent_invitation_email_attempts_for(user)
          return @recent_invitation_email_attempts_by_user_id.fetch(user.id, []) if defined?(@recent_invitation_email_attempts_by_user_id)

          user.invitation_email_attempts.includes(:sent_by_user).recent_first.limit(5).to_a.reverse
        end

        def preload_recent_invitation_email_attempts(users)
          @recent_invitation_email_attempts_by_user_id = Hash.new { |hash, user_id| hash[user_id] = [] }
          user_ids = users.map(&:id)
          return if user_ids.empty?

          ranked_attempts_sql = InvitationEmailAttempt
            .where(user_id: user_ids)
            .select("invitation_email_attempts.*, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY attempted_at DESC, id DESC) AS attempt_rank")
            .to_sql

          attempts = InvitationEmailAttempt
            .from("(#{ranked_attempts_sql}) invitation_email_attempts")
            .where("attempt_rank <= ?", 5)
            .includes(:sent_by_user)
            .order(:user_id, :attempted_at, :id)
            .to_a

          attempts.each do |attempt|
            @recent_invitation_email_attempts_by_user_id[attempt.user_id] << attempt
          end
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
