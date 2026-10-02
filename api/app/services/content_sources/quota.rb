# frozen_string_literal: true

module ContentSources
  class Quota
    def initialize(scope:, user:, workspace: nil)
      @scope = scope.to_s
      @user = user
      @workspace = workspace
    end

    def owner_key
      scope == "coach" ? "workspace-#{workspace&.id}" : "platform-user-#{user.id}"
    end

    def enforce!(requested_bytes:, exclude_intake: nil, enforce_rate: true)
      sources = source_scope.where.not(status: "source_deleted")
      reservations = intake_scope.reserving_quota
      reservations = reservations.where.not(id: exclude_intake.id) if exclude_intake
      active_count = sources.count + reservations.count
      active_bytes = sources.sum(:byte_size) + reservations.sum(:reserved_bytes)
      if active_count >= CoachContentSource::MAX_ACTIVE_SOURCES_PER_OWNER ||
          active_bytes + requested_bytes.to_i > CoachContentSource::MAX_ACTIVE_BYTES_PER_OWNER
        raise Error, "source_quota_reached"
      end

      uploads_in_flight = sources.where(status: %w[uploading verifying upload_cleanup upload_cleanup_failed]).count
      if uploads_in_flight + reservations.count >= CoachContentSource::MAX_IN_FLIGHT_UPLOADS_PER_OWNER
        raise Error, "upload_limit_reached"
      end

      if enforce_rate
        cutoff = CoachContentSource::UPLOAD_WINDOW.ago
        recent_uploads = source_scope.where(ingestion_method: "upload")
          .where("coach_content_sources.created_at >= ?", cutoff).count
        recent_url_attempts = intake_scope.joins(:attempts)
          .where("coach_content_source_url_intake_attempts.created_at >= ?", cutoff).count
        if recent_uploads + recent_url_attempts >= CoachContentSource::MAX_NEW_UPLOADS_PER_WINDOW
          raise Error, "upload_rate_limited"
        end
      end
      true
    end

    def source_scope
      if scope == "coach"
        CoachContentSource.where(scope: "coach", coach_workspace: workspace)
      else
        CoachContentSource.where(scope: "platform", created_by_user: user, coach_workspace: nil)
      end
    end

    def intake_scope
      if scope == "coach"
        CoachContentSourceUrlIntake.where(scope: "coach", coach_workspace: workspace)
      else
        CoachContentSourceUrlIntake.where(scope: "platform", created_by_user: user, coach_workspace: nil)
      end
    end

    private

    attr_reader :scope, :user, :workspace
  end
end
