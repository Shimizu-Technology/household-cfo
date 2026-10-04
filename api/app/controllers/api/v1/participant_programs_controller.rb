module Api
  module V1
    class ParticipantProgramsController < BaseController
      PAGE_SIZE = 50

      before_action :private_response
      before_action :authenticate_user!

      def index
        unless current_user.participant?
          render json: { errors: [ "Participant program selection is unavailable for this account." ] }, status: :forbidden
          return
        end

        workspace = authorized_program_brand
        cursor = cursor_id
        programs = Cohort.where(id: current_user.cohort_memberships.where(role: "participant").select(:cohort_id))
        programs = programs.where(coach_workspace_id: workspace.id) if workspace
        rows = programs.where("cohorts.id > ?", cursor).order(:id).limit(PAGE_SIZE + 1).to_a
        current, unavailable = current_program(workspace)
        page = rows.first(PAGE_SIZE)
        render json: {
          actor_id: current_user.id,
          current_cohort_id: current&.id,
          current_program: current && program_metadata(current),
          selection_unavailable: unavailable,
          programs: page.map { |program| program_metadata(program) },
          next_cursor: rows.size > PAGE_SIZE ? page.last.id : nil
        }
      rescue ArgumentError
        render json: { errors: [ "Use a valid program page cursor." ] }, status: :unprocessable_entity
      end

      private

      def private_response
        response.set_header("Cache-Control", "private, no-store")
      end

      def authorized_program_brand
        workspace = participant_brand_workspace
        origin = request.headers["Origin"].to_s.strip
        if origin.present? && workspace.nil?
          hostname = Branding::Hostname.from_origin(origin)
          reject_unavailable_brand! unless Branding::Hostname::LOCAL.include?(hostname) || Branding::Hostname.legacy?(hostname)
        end
        workspace
      end

      def cursor_id
        raw = params[:cursor]
        return 0 if raw.nil?
        raise ArgumentError unless raw.to_s.match?(/\A\d+\z/)

        Integer(raw, 10)
      end

      def current_program(workspace)
        membership = Mia::EffectiveCohortResolver.new(
          user: current_user, role: "participant", coach_workspace: workspace,
          requested_cohort_id: request.headers["X-Cohort-Id"]
        ).call
        [ membership&.cohort, false ]
      rescue Mia::EffectiveCohortResolver::InvalidSelection
        [ nil, request.headers["X-Cohort-Id"].present? ]
      end

      def program_metadata(program)
        { id: program.id, name: program.name, status: program.status }
      end
    end
  end
end
