module Api
  module V1
    module Admin
      class CohortsController < BaseController
        before_action :authenticate_user!
        before_action :require_admin!

        def index
          cohorts = Cohort.includes(:created_by_user, cohort_memberships: { user: { household_memberships: :household } }).order(created_at: :desc)
          render json: { cohorts: cohorts.map { |cohort| serialize_cohort(cohort) } }
        end

        def show
          cohort = Cohort.includes(:created_by_user, cohort_memberships: { user: { household_memberships: :household } }).find(params[:id])
          render json: { cohort: serialize_cohort(cohort, include_members: true) }
        end

        def create
          cohort = Cohort.create!(cohort_params.merge(created_by_user: current_user))
          render json: { cohort: serialize_cohort(cohort.reload) }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        def update
          cohort = Cohort.find(params[:id])
          cohort.update!(cohort_params)
          render json: { cohort: serialize_cohort(cohort.reload, include_members: true) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        private

        def cohort_params
          params.require(:cohort).permit(:name, :status, :starts_on, :ends_on, :notes)
        end

        def serialize_cohort(cohort, include_members: false)
          memberships = cohort.cohort_memberships.to_a
          member_users = memberships.map(&:user)
          setup_complete_count = member_users.count { |user| setup_complete?(user) }
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
                  setup_complete: setup_complete?(membership.user)
                }
              }
            end
          end

          payload
        end

        def setup_complete?(user)
          household = user.household_memberships.sort_by(&:created_at).first&.household
          return false unless household

          HouseholdFinance::SnapshotBuilder.new(household).call.fetch(:profile_completeness) >= 70
        end
      end
    end
  end
end
