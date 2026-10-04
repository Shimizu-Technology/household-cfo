module Api
  module V1
    # Operational roster metadata and fixed reports only; never resolves a
    # participant financial workspace for the staff actor.
    class ChallengeCohortsController < BaseController
      wrap_parameters false
      before_action :authenticate_user!
      before_action :disable_caching!
      before_action :reject_filters!
      rescue_from ArgumentError do |error|
        render json: { errors: [ error.message ] }, status: :unprocessable_entity
      end
      rescue_from ActiveRecord::RecordNotFound do
        render json: { errors: [ "Challenge record not found" ] }, status: :not_found
      end
      rescue_from ChallengePrivacy::Access::Denied do |error|
        render json: { errors: [ error.message ] }, status: :forbidden
      end

      def participants
        ChallengePrivacy::Access.staff!(cohort, current_user)
        rows = page(SavingsEnrollment.where(cohort: cohort).includes(:user))
        records = rows.first(50).filter_map do |enrollment|
          basic = ChallengePrivacy::SharedReader.new(enrollment, user: current_user).basic
          { **basic, participant: { id: enrollment.user_id, name: enrollment.user.full_name.presence || enrollment.user.email } }
        rescue ChallengePrivacy::Access::Denied
          nil
        end
        render json: { **staff_scope, cohort_id: cohort.id, records: records, next_cursor: rows.length > 50 ? rows[49].id : nil }
      end

      def exports
        ChallengePrivacy::Access.staff!(cohort, current_user, export: true)
        rows = page(ChallengeSponsorExport.where(cohort: cohort))
        render json: { **staff_scope, cohort_id: cohort.id, scheduled_checkpoints: [ 30, 60, 90 ].map { |day| { day: day, cutoff_on: cohort.starts_on && (cohort.starts_on + day - 1).iso8601 } },
          records: rows.first(50).map { |record| record.attributes.slice("id", "checkpoint_day", "resolved_cutoff_on", "policy_version", "created_at") }, next_cursor: rows.length > 50 ? rows[49].id : nil }
      end

      def approve_export
        input = request.request_parameters.to_h
        raise ArgumentError, "Review a fixed checkpoint without filters" unless input.keys.sort == %w[accepted checkpoint_day] && input["accepted"] == true
        day = SavingsChallenge::Inputs.integer!(input["checkpoint_day"], minimum: 30, maximum: 90)
        raise ArgumentError, "Choose Day 30, 60 or 90" unless day.in?([ 30, 60, 90 ])
        raise ChallengePrivacy::Access::Denied, "Configure the cohort start before reporting" unless cohort.starts_on
        report = exporter.approve(checkpoint_day: day, resolved_cutoff_on: (cohort.starts_on + day - 1).iso8601)
        record = ChallengeSponsorExport.find_by!(cohort: cohort, checkpoint_day: day, policy_version: ChallengePrivacy::SponsorExports::POLICY_VERSION)
        render json: { **staff_scope, cohort_id: cohort.id, export_id: record.id, report: report }
      end

      def export
        raise ArgumentError, "Fixed exports do not accept filters" unless (params.to_unsafe_h.keys - %w[controller action cohort_id id format]).empty?
        id = SavingsChallenge::Inputs.id!(params[:id])
        if params[:format] == "csv"
          send_data exporter.csv(id), filename: "cohort-checkpoint-#{id}.csv", type: "text/csv", disposition: "attachment"
        else
          render json: { **staff_scope, cohort_id: cohort.id, export_id: id, report: exporter.read(id) }
        end
      end

      private
      def disable_caching! = response.set_header("Cache-Control", "private, no-store")
      def reject_filters!
        allowed = action_name.in?(%w[participants exports]) ? %w[cursor] : []
        raise ArgumentError, "This fixed challenge view does not accept subgroup filters" unless (request.query_parameters.keys - allowed).empty?
      end
      def cohort
        @cohort ||= Cohort.find(SavingsChallenge::Inputs.id!(params[:cohort_id]))
      end
      def exporter = ChallengePrivacy::SponsorExports.new(cohort, user: current_user)
      def staff_scope = { actor_scope: { user_id: current_user.id, coach_workspace_id: cohort.coach_workspace_id } }
      def page(scope)
        cursor = SavingsChallenge::Inputs.id!(params[:cursor].presence, nullable: true)
        scope = scope.where("#{scope.klass.table_name}.id > ?", cursor) if cursor
        scope.order(:id).limit(51).to_a
      end
    end
  end
end
