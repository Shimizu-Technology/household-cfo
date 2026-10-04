module ChallengePrivacy
  class SharedReader
    def initialize(enrollment, user:) = (@enrollment, @user = enrollment, user)
    def basic
      guarded do
        { enrollment_id: @enrollment.id, participation_status: @enrollment.status,
          setup_status: @enrollment.current_accepted_plan_version_id ? "plan_reviewed" : "plan_pending",
          check_in: attendance_metadata,
          help_requests: ChallengeSupportTicket.where(savings_enrollment: @enrollment, recipient_user: @user).order(:id).limit(50).map { |ticket| { id: ticket.id, status: ticket.status, issue_kind: ticket.issue_kind } },
          more_help_requests: ChallengeSupportTicket.where(savings_enrollment: @enrollment, recipient_user: @user).count > 50 }
      end
    end

    def summary
      guarded(financial: true) do
        grant!("coach_summary")
        projection = SavingsChallenge::Projection.new(@enrollment).call
        audit!("coach_summary", "SavingsEnrollment", @enrollment.id)
        { enrollment_id: @enrollment.id, accepted_target_cents: @enrollment.current_accepted_plan_version&.target_cents,
          projection: projection.slice(:reported_cents, :evidence_supported_cents, :reporting_known, :achieved) }
      end
    end

    def shared_scopes
      guarded(financial: true) do
        summary = ChallengePrivacyGrant.find_by(savings_enrollment: @enrollment, recipient_user: @user, kind: "coach_summary")
        details = ChallengePrivacyGrant.find_by(savings_enrollment: @enrollment, recipient_user: @user, kind: "selected_details")
        supports = ChallengeSupportAccess.where(savings_enrollment: @enrollment, recipient_user: @user).order(:id).select(&:active?)
        { enrollment_id: @enrollment.id, summary_available: summary&.active? == true,
          selected_records: details&.active? ? details.selected_records : [],
          support_access: supports.map { |access| { id: access.id, expires_at: access.expires_at, selected_records: access.selected_records } } }
      end
    end

    def help_page(after_id: nil)
      guarded do
        cursor = SavingsChallenge::Inputs.id!(after_id, nullable: true)
        scope = ChallengeSupportTicket.where(savings_enrollment: @enrollment, recipient_user: @user)
        scope = scope.where("id > ?", cursor) if cursor
        rows = scope.order(:id).limit(51).to_a
        { records: rows.first(50).map { |ticket| { id: ticket.id, status: ticket.status, issue_kind: ticket.issue_kind } },
          next_cursor: rows.length > 50 ? rows[49].id : nil }
      end
    end

    # Returns only the exact authorized model for the root's separate minimized
    # serializer/proxy. Never serializes .attributes or returns a storage URL.
    def selected(record_type:, record_id:, support_access_id: nil)
      guarded(financial: true) do
        selected = { record_type: record_type, record_id: record_id }
        if support_access_id
          grant = ChallengeSupportAccess.where(savings_enrollment: @enrollment, recipient_user: @user).find(support_access_id)
          raise Access::Denied, "Support access has expired or was revoked" unless grant.active?
          purpose = "support"
        else
          grant = grant!("selected_details")
          purpose = "selected_details"
        end
        raise Access::Denied, "That record was not selected for sharing" unless grant.selected_records.include?(selected.stringify_keys)
        record = RecordSelector.new(@enrollment).resolve!(selected)
        audit!(purpose, record_type, record_id)
        record
      end
    end

    def support_ticket(ticket_id)
      guarded do
        ticket = ChallengeSupportTicket.where(savings_enrollment: @enrollment, recipient_user: @user).find(ticket_id)
        audit!("support_ticket", "ChallengeSupportTicket", ticket.id)
        { id: ticket.id, issue_kind: ticket.issue_kind, message: ticket.message, status: ticket.status, selected_records: ticket.selected_records }
      end
    end

    def update_support_status(ticket_id, status:)
      raise ArgumentError, "Choose triaged or resolved status" unless status.in?(%w[triaged resolved])
      guarded do
        ticket = ChallengeSupportTicket.where(savings_enrollment: @enrollment, recipient_user: @user).lock.find(ticket_id)
        ticket.update!(status: status)
        audit!("support_status_#{status}", "ChallengeSupportTicket", ticket.id)
        { id: ticket.id, status: ticket.status }
      end
    end

    private
    def attendance_metadata
      on = @enrollment.local_today
      active = @enrollment.status == "active" && on.between?(@enrollment.starts_on, @enrollment.ends_on)
      return { local_on: on.iso8601, completed: nil, availability: "outside_active_window" } unless active
      SavingsChallenge::Daily::ReadPolicy.call!(@enrollment, user: @enrollment.user)
      { local_on: on.iso8601, completed: ChallengeReminders::Attendance.new.completed?(enrollment: @enrollment, local_on: on), availability: "available" }
    rescue SavingsChallenge::AccessPolicy::Unavailable, ArgumentError, ActiveRecord::RecordNotFound
      { local_on: on.iso8601, completed: nil, availability: "unavailable" }
    end
    def guarded(financial: false)
      ApplicationRecord.transaction do
        @enrollment.household.lock!
        @enrollment.reload
        Access.staff!(@enrollment, @user)
        Access.participant_current!(@enrollment)
        if financial
          CohortReleases::OperationAccess.require!(household: @enrollment.household, user: @enrollment.user,
            key: "privacy.consent.set", cohort: @enrollment.cohort)
          SavingsChallenge::AccessPolicy.new(household: @enrollment.household, user: @enrollment.user, cohort: @enrollment.cohort, enrollment: @enrollment).call!
        end
        yield
      end
    end
    def grant!(kind)
      grant = ChallengePrivacyGrant.find_by(savings_enrollment: @enrollment, recipient_user: @user, kind: kind)
      raise Access::Denied, "The participant has not shared that scope" unless grant&.active?
      grant
    end
    def audit!(purpose, type, id)
      ChallengePrivacyRead.create!(household: @enrollment.household, savings_enrollment: @enrollment,
        participant_user: @enrollment.user, actor_user: @user, purpose: purpose, record_type: type, record_id: id, created_at: Time.current)
    end
  end
end
