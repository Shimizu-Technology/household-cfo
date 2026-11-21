module Api
  module V1
    # Operational roster metadata and fixed reports only; never resolves a
    # participant financial workspace for the staff actor.
    class ChallengeCohortsController < BaseController
      wrap_parameters false
      STAFF_DENIED = "Only this group's coaches can see this. Ask a platform admin to add you as a coach of this group."
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
        message = error.message == ChallengePrivacy::Access::UNAVAILABLE ? STAFF_DENIED : error.message
        render json: { errors: [ message ] }, status: :forbidden
      end

      def participants
        if params[:view] == "daily"
          ChallengePrivacy::Access.roster!(cohort, current_user)
          result = ChallengePrivacy::CoachDailyRoster.new(cohort, user: current_user).call(search: params[:search], filter: params[:filter], offset: params[:offset])
          return render json: { **staff_scope, cohort_id: cohort.id, **result }
        end
        ChallengePrivacy::Access.staff!(cohort, current_user)
        rows = page(SavingsEnrollment.counted.where(cohort: cohort).includes(:user))
        records = rows.first(50).filter_map do |enrollment|
          basic = ChallengePrivacy::SharedReader.new(enrollment, user: current_user).basic
          { **basic, participant: { id: enrollment.user_id, name: enrollment.user.full_name.presence || enrollment.user.email } }
        rescue ChallengePrivacy::Access::Denied
          nil
        end
        render json: { **staff_scope, cohort_id: cohort.id, records: records, next_cursor: rows.length > 50 ? rows[49].id : nil }
      end

      def exports
        ChallengePrivacy::Access.export_reader!(cohort, current_user)
        rows = page(ChallengeSponsorExport.where(cohort: cohort))
        # A platform administrator reads reports; only the program's owner or reviewer seals them.
        render json: { **staff_scope, cohort_id: cohort.id, today_on: Date.current.iso8601,
          can_seal: ChallengePrivacy::Access.staff_allowed?(cohort, current_user, export: true),
          scheduled_checkpoints: scheduled_checkpoints, rules_notice: rules_notice,
          records: rows.first(50).map { |record| record.attributes.slice("id", "checkpoint_day", "resolved_cutoff_on", "policy_version", "created_at") }, next_cursor: rows.length > 50 ? rows[49].id : nil }
      end

      def approve_export
        # Permission first, so a person who may not seal reports never learns
        # anything about the request shape from a validation error.
        ChallengePrivacy::Access.staff!(cohort, current_user, export: true)
        input = request.request_parameters.to_h
        raise ArgumentError, "Review a fixed checkpoint without filters" unless input.keys.sort == %w[accepted checkpoint_day] && input["accepted"] == true
        days = ChallengePrivacy::SponsorExports.reportable_days(cohort)
        day = SavingsChallenge::Inputs.integer!(input["checkpoint_day"], minimum: 1, maximum: CohortExperience::MethodSettings::CHALLENGE_LENGTHS.end)
        raise ArgumentError, "Choose #{ChallengePrivacy::SponsorExports.day_choice_text(days)}" unless days.include?(day)
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

      # The group's live check-in days, every day on a schedule someone joined under,
      # and any day already sealed, so each report stays listed and reachable.
      def scheduled_checkpoints
        ChallengePrivacy::SponsorExports.reportable_days(cohort).map do |day|
          { day: day, cutoff_on: cohort.starts_on && (cohort.starts_on + day - 1).iso8601, sealable: cohort.starts_on.present? && cohort.starts_on + day - 1 <= Date.current }
        end
      end
      # Said on the reports screen when the live release's challenge settings could not be read.
      def rules_notice
        SavingsChallenge::Rules.read_release(cohort.active_cohort_release).last ? nil : SavingsChallenge::Rules.unreadable_notice
      end
      def disable_caching! = response.set_header("Cache-Control", "private, no-store")
      def reject_filters!
        allowed = if action_name == "participants" && params[:view] == "daily"
          %w[view search filter offset]
        else
          action_name.in?(%w[participants exports]) ? %w[cursor] : []
        end
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
