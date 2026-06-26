module Api
  module V1
    module Admin
      class CohortsController < BaseController
        before_action :authenticate_user!
        before_action :require_admin!
        rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

        def index
          cohorts = Cohort.includes(cohort_list_includes).order(created_at: :desc).to_a
          setup_counts = setup_complete_counts_for_cohorts(cohorts.map(&:id))
          render json: { cohorts: cohorts.map { |cohort| serialize_cohort(cohort, include_setup: false, setup_complete_count: setup_counts.fetch(cohort.id, 0)) } }
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
            { cohort_memberships: { user: { household_memberships: { household: %i[income_sources expense_items debts accounts goals] } } } }
          ]
        end

        def serialize_cohort(cohort, include_members: false, include_setup: true, setup_complete_count: nil)
          memberships = cohort.cohort_memberships.to_a
          member_users = memberships.map(&:user)
          setup_complete_by_user_id = include_setup ? member_users.to_h { |user| [ user.id, setup_complete?(user) ] } : {}
          setup_complete_count ||= include_setup ? setup_complete_by_user_id.values.count(true) : 0
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
                  setup_complete: setup_complete_by_user_id.fetch(membership.user.id)
                }
              }
            end
          end

          payload
        end

        def setup_complete_counts_for_cohorts(cohort_ids)
          return {} if cohort_ids.empty?

          sql = ApplicationRecord.sanitize_sql_array([
            <<~SQL.squish,
              SELECT cohort_memberships.cohort_id, COUNT(DISTINCT cohort_memberships.user_id) AS setup_complete_count
              FROM cohort_memberships
              INNER JOIN household_memberships ON household_memberships.user_id = cohort_memberships.user_id
              INNER JOIN households ON households.id = household_memberships.household_id
              WHERE cohort_memberships.cohort_id IN (?)
                AND (
                  CASE WHEN NULLIF(TRIM(households.name), '') IS NOT NULL THEN 1 ELSE 0 END +
                  CASE WHEN NULLIF(TRIM(households.primary_goal), '') IS NOT NULL THEN 1 ELSE 0 END +
                  CASE WHEN EXISTS (SELECT 1 FROM income_sources WHERE income_sources.household_id = households.id AND income_sources.active = TRUE AND income_sources.amount_cents > 0) THEN 1 ELSE 0 END +
                  CASE WHEN EXISTS (SELECT 1 FROM expense_items WHERE expense_items.household_id = households.id AND expense_items.active = TRUE AND expense_items.amount_cents > 0) THEN 1 ELSE 0 END +
                  CASE WHEN EXISTS (SELECT 1 FROM accounts WHERE accounts.household_id = households.id AND accounts.balance_cents > 0) THEN 1 ELSE 0 END +
                  CASE WHEN EXISTS (SELECT 1 FROM debts WHERE debts.household_id = households.id) OR EXISTS (SELECT 1 FROM accounts WHERE accounts.household_id = households.id) THEN 1 ELSE 0 END +
                  CASE WHEN EXISTS (SELECT 1 FROM goals WHERE goals.household_id = households.id) THEN 1 ELSE 0 END
                ) >= 5
              GROUP BY cohort_memberships.cohort_id
            SQL
            cohort_ids
          ])

          ApplicationRecord.connection.exec_query(sql).to_h do |row|
            [ row.fetch("cohort_id"), row.fetch("setup_complete_count") ]
          end
        end

        def setup_complete?(user)
          household = user.household_memberships.sort_by(&:created_at).first&.household
          return false unless household

          HouseholdFinance::SnapshotBuilder.new(household).call.fetch(:profile_completeness) >= 70
        end

        def render_not_found(error)
          render json: { errors: [ error.message ] }, status: :not_found
        end
      end
    end
  end
end
