module Api
  module V1
    module Admin
      class CohortsController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!
        before_action :require_group_management!
        before_action :require_selected_coach_workspace!, only: %i[create remove_participant]
        rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
        rescue_from Mia::PersonaAssignmentCompatibility::Conflict, with: :render_persona_assignment_conflict

        def index
          cohorts = workspace_cohorts.includes(cohort_list_includes).order(created_at: :desc).to_a
          setup_counts = setup_complete_counts_for_cohorts(cohorts)
          render json: { cohorts: cohorts.map { |cohort| serialize_cohort(cohort, setup_complete_count: setup_counts.fetch(cohort.id, 0)) } }
        end

        def show
          cohort = find_cohort(params[:id])
          render json: { cohort: serialize_cohort(cohort, include_members: true) }
        end

        def create
          cohort = Cohort.create!(cohort_params.merge(created_by_user: current_user, coach_workspace: current_coach_workspace))
          render json: { cohort: serialize_cohort(cohort) }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        def update
          cohort = workspace_cohorts.find(params[:id])
          Cohort.transaction do
            cohort.lock!
            if params.dig(:cohort, :expected_updated_at).present? && params.dig(:cohort, :expected_updated_at).to_s != cohort.updated_at.iso8601(6)
              return render json: { error: "This group changed. Reload it before saving.", code: "group_conflict" }, status: :conflict
            end
            if !current_user.admin? && params.dig(:cohort, :expected_updated_at).blank?
              return render json: { error: "Reload this group before saving.", code: "group_conflict" }, status: :conflict
            end
            if activating_persona_assignment?(cohort)
              participant_ids = Mia::PersonaAssignmentCompatibility.participant_ids_for(cohort: cohort)
              Mia::PersonaAssignmentCompatibility.lock_participants!(user_ids: participant_ids)
              assignment = cohort.cohort_persona_assignment
              Mia::PersonaAssignmentCompatibility.ensure_cohort_can_use!(cohort: cohort, persona: assignment.coach_persona) if assignment
            end
            cohort.update!(cohort_params)
          end
          render json: { cohort: serialize_cohort(find_cohort(cohort.id), include_members: true) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        # Enrollment belongs to a program; removing it must never revoke the
        # participant's global account or their access to other programs.
        def remove_participant
          cohort = workspace_cohorts.find(params[:id])
          removed = false
          Cohort.transaction do
            cohort.lock!
            membership = cohort.cohort_memberships.find_by(user_id: params[:user_id], role: "participant")
            # An already absent enrollment is a safe replay. Do not inspect an
            # unrelated account or disclose whether that global user exists.
            next unless membership
            user = User.lock.find(membership.user_id)
            raise ActiveRecord::RecordNotFound unless user.participant?
            if membership.id.to_s != params[:expected_membership_id].to_s
              return render json: { error: "This enrollment changed. Reload the roster before removing it.", code: "enrollment_conflict" }, status: :conflict
            end
            membership.destroy!
            removed = true
          end
          render json: { removed: removed, cohort_id: cohort.id }
        end

        private

        def require_group_management!
          return if current_user.admin?
          if request.headers["X-Coach-Workspace-Id"].blank?
            return render json: { error: "Choose a program before managing groups.", code: "coach_workspace_required" }, status: :unprocessable_entity
          end
          render_forbidden("Program owner access required") unless coach_workspace_for_policy&.allows?(current_user, :manage_members)
        end

        def cohort_params
          params.require(:cohort).permit(:name, :status, :starts_on, :ends_on, :notes)
        end

        def activating_persona_assignment?(cohort)
          requested_status = cohort_params[:status].presence
          requested_status.in?(Mia::PersonaAssignmentCompatibility::RELEVANT_COHORT_STATUSES) &&
            !cohort.status.in?(Mia::PersonaAssignmentCompatibility::RELEVANT_COHORT_STATUSES)
        end

        def find_cohort(id)
          workspace_cohorts.includes(cohort_includes).find(id)
        end

        def workspace_cohorts
          @workspace_cohorts ||= coach_workspace_for_policy ? Cohort.where(coach_workspace: coach_workspace_for_policy) : Cohort.all
        end

        def cohort_list_includes
          [
            :created_by_user,
            { cohort_memberships: :user }
          ]
        end

        def cohort_includes
          [
            :created_by_user,
            { cohort_memberships: :user }
          ]
        end

        def serialize_cohort(cohort, include_members: false, setup_complete_count: nil)
          memberships = memberships_with_users(cohort)
          member_users = memberships.map(&:user)
          participant_users = memberships.select { |membership| membership.role == "participant" }.map(&:user)
          progress_by_user_id = include_members ? HouseholdFinance::PilotProgressBatchBuilder.new(member_users).call : {}
          setup_complete_count ||= progress_by_user_id.values.count { |progress| progress.fetch(:setup_complete) }
          participant_count = memberships.count { |membership| membership.role == "participant" }
          staff_count = memberships.count { |membership| membership.role.in?([ "coach", "admin" ]) }

          payload = {
            id: cohort.id,
            name: cohort.name,
            status: cohort.status,
            starts_on: cohort.starts_on,
            ends_on: cohort.ends_on,
            notes: cohort.notes.to_s,
            member_count: memberships.size,
            participant_count: participant_count,
            staff_count: staff_count,
            setup_complete_count: setup_complete_count,
            operational_summary: operational_summary(cohort, participant_users),
            created_at: cohort.created_at,
            updated_at: cohort.updated_at.iso8601(6),
            created_by: {
              id: cohort.created_by_user.id,
              email: cohort.created_by_user.email,
              full_name: cohort.created_by_user.full_name
            }
          }

          if include_members
            payload[:members] = memberships.sort_by { |membership| [ membership.role, membership.user.email ] }.map do |membership|
              {
                id: membership.id,
                role: membership.role,
                user: {
                  id: membership.user.id,
                  email: membership.user.email,
                  full_name: membership.user.full_name,
                  role: membership.user.role,
                  invitation_status: membership.user.invitation_status,
                  **progress_by_user_id.fetch(membership.user.id)
                }
              }
            end
          end

          payload
        end

        def setup_complete_counts_for_cohorts(cohorts)
          memberships_by_cohort_id = cohorts.to_h { |cohort| [ cohort.id, memberships_with_users(cohort) ] }
          users = memberships_by_cohort_id.values.flatten.map(&:user).uniq(&:id)
          progress_by_user_id = HouseholdFinance::PilotProgressBatchBuilder.new(users).call

          cohorts.to_h do |cohort|
            complete_count = memberships_by_cohort_id.fetch(cohort.id).count do |membership|
              progress_by_user_id.fetch(membership.user.id, {}).fetch(:setup_complete, false)
            end
            [ cohort.id, complete_count ]
          end
        end

        def memberships_with_users(cohort)
          cohort.cohort_memberships.to_a.select { |membership| membership.user.present? }
        end

        def operational_summary(cohort, users)
          household_ids = HouseholdMembership.where(user_id: users.map(&:id)).distinct.pluck(:household_id)
          since = 7.days.ago
          events = HouseholdAuditEvent.where(household_id: household_ids, occurred_at: since..)
          completed = events.where(event_type: "mia.request.completed")
          durations = completed.pluck(:metadata).filter_map do |metadata|
            Integer(metadata.to_h["duration_ms"], exception: false)
          end
          imports = FinancialDocumentImport.where(household_id: household_ids, created_at: since..)
          {
            available: true,
            period_days: 7,
            mia_requests: completed.count,
            mia_failures: events.where(event_type: "mia.request.failed").count,
            average_mia_latency_ms: durations.any? ? (durations.sum.to_f / durations.length).round : nil,
            uploads: imports.count,
            upload_failures: imports.where(status: "failed").count,
            participants_active: events.where(user_id: users.map(&:id)).distinct.count(:user_id)
          }
        rescue ActiveRecord::StatementInvalid => e
          Rails.logger.warn("Cohort operational summary unavailable cohort_id=#{cohort.id}: #{e.class}")
          {
            available: false,
            period_days: 7,
            mia_requests: nil,
            mia_failures: nil,
            average_mia_latency_ms: nil,
            uploads: nil,
            upload_failures: nil,
            participants_active: nil
          }
        end

        def render_not_found(error)
          render json: { errors: [ error.message ] }, status: :not_found
        end

        def render_persona_assignment_conflict(error)
          render json: { error: error.message, code: "persona_assignment_conflict" }, status: :conflict
        end
      end
    end
  end
end
