module Api
  module V1
    module Admin
      class CohortsController < BaseController
        before_action :authenticate_user!
        before_action :require_admin!
        rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

        def index
          cohorts = Cohort.includes(cohort_list_includes).order(created_at: :desc).to_a
          setup_counts = setup_complete_counts_for_cohorts(cohorts)
          render json: { cohorts: cohorts.map { |cohort| serialize_cohort(cohort, setup_complete_count: setup_counts.fetch(cohort.id, 0)) } }
        end

        def show
          cohort = find_cohort(params[:id])
          render json: { cohort: serialize_cohort(cohort, include_members: true) }
        end

        def create
          cohort = Cohort.create!(cohort_params.merge(created_by_user: current_user))
          render json: { cohort: serialize_cohort(cohort) }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        def update
          cohort = Cohort.find(params[:id])
          cohort.update!(cohort_params)
          render json: { cohort: serialize_cohort(find_cohort(cohort.id), include_members: true) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        private

        def cohort_params
          params.require(:cohort).permit(:name, :status, :starts_on, :ends_on, :notes)
        end

        def find_cohort(id)
          Cohort.includes(cohort_includes).find(id)
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
          memberships = cohort.cohort_memberships.to_a
          member_users = memberships.map(&:user)
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
            created_at: cohort.created_at,
            updated_at: cohort.updated_at,
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
          users = cohorts.flat_map { |cohort| cohort.cohort_memberships.map(&:user) }
          progress_by_user_id = HouseholdFinance::PilotProgressBatchBuilder.new(users).call

          cohorts.to_h do |cohort|
            complete_count = cohort.cohort_memberships.count do |membership|
              progress_by_user_id.fetch(membership.user_id).fetch(:setup_complete)
            end
            [ cohort.id, complete_count ]
          end
        end

        def render_not_found(error)
          render json: { errors: [ error.message ] }, status: :not_found
        end
      end
    end
  end
end
