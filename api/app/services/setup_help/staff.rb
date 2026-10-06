module SetupHelp
  class Staff
    def initialize(user:, workspace_id: nil)
      @user, @workspace_id = user, workspace_id
    end

    def list(cohort_id: nil, cursor: nil, limit: nil)
      scope = authorized_scope
      scope = scope.where(cohort_id: positive_id!(cohort_id)) if cohort_id.present?
      scope = scope.where("setup_support_requests.id > ?", positive_id!(cursor)) if cursor.present?
      page_size = limit.present? ? positive_id!(limit) : 25
      raise Error, "Choose at most 50 support requests per page." if page_size > 50
      rows = scope.order(:id).limit(page_size + 1).to_a
      visible = rows.first(page_size).filter_map do |record|
        record.household.with_lock do
          Access.staff!(record, user: @user)
          Serializer.request(record, permissions: Access.permissions(record, user: @user))
        end
      rescue Denied
        nil
      end
      { records: visible, next_cursor: rows.length > page_size ? rows[page_size - 1].id : nil }
    end

    def transition(id:, action:, expected_lock_version:)
      record = authorized_scope.find(id)
      record.household.with_lock do
        record.reload
        actor = Access.staff!(record, user: @user, action: action)
        participant = Participant.new(record.household, user: record.requested_by_user,
          cohort_membership: record.cohort&.cohort_memberships&.find_by(id: record.participant_membership_id))
        participant.check_version!(record, expected_lock_version)
        raise Error, "This setup request has already finished. Nothing changed." unless SetupSupportRequest::ACTIVE.include?(record.status)
        case action
        when "triage"
          raise Error, "The participant already has a prepared review. Nothing changed." if record.status == "ready"
          record.update!(status: "in_review")
        when "prepare"
          core = HouseholdFinance::FinancialRestart::Core.new(record.household, user: record.requested_by_user)
          core.cancel_review!(record.financial_restart_review) if record.financial_restart_review
          review = core.create_review!(cohort_id: record.cohort_id, purpose: "supported_setup", support_request: record)
          record.update!(status: "ready", prepared_by_user: actor, financial_restart_review: review)
        when "decline"
          HouseholdFinance::FinancialRestart::Core.new(record.household, user: record.requested_by_user).cancel_review!(record.financial_restart_review) if record.financial_restart_review
          record.update!(status: "declined")
        else
          raise Error, "Choose a supported setup help action."
        end
        record.household.household_audit_events.create!(user: actor, actor_type: "user", event_type: "setup_support.#{action}",
          auditable_type: "SetupSupportRequest", auditable_id: record.id, occurred_at: Time.current,
          metadata: { requested_by_user_id: record.requested_by_user_id, prepared_by_user_id: record.prepared_by_user_id,
            cohort_id: record.cohort_id, review_id: record.financial_restart_review_id, status: record.status, lock_version: record.lock_version })
        { request: Serializer.request(record, permissions: Access.permissions(record, user: @user)) }
      end
    end

    private
    def authorized_scope
      actor = User.find_by(id: @user&.id)
      raise Denied, "Setup support is unavailable for this account." unless actor&.staff? && actor.invitation_accepted? && !actor.revoked?
      workspace_ids = CoachWorkspaceMembership.where(user_id: actor.id).select(:coach_workspace_id)
      programs = Cohort.where(coach_workspace_id: workspace_ids).where(id: CohortMembership.where(user_id: actor.id, role: %w[coach admin]).select(:cohort_id))
        .or(Cohort.where(coach_workspace_id: workspace_ids, created_by_user_id: actor.id))
      programs = programs.where(coach_workspace_id: positive_id!(@workspace_id)) if @workspace_id.present?
      scope = SetupSupportRequest.where(cohort_id: programs.select(:id))
      if actor.admin? && @workspace_id.blank?
        ordinary = ChallengePrivacy::PrivateFinanceAccess.without_pilot_households(SetupSupportRequest.where(cohort_id: nil))
        scope = scope.or(ordinary)
      end
      scope
    end
    def positive_id!(value)
      text = value.to_s
      raise Error, "Use an exact positive record identity." unless text.match?(/\A[1-9]\d*\z/)
      text.to_i
    end
  end
end
