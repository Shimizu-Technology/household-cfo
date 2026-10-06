require "digest"

module SetupHelp
  class Participant
    def initialize(household, user:, cohort_membership: nil)
      @household, @user, @membership = household, user, cohort_membership
    end

    def status
      @household.with_lock do
        Access.participant!(@household, user: @user, cohort_membership: @membership)
        owner = @household.household_memberships.exists?(user_id: @user.id, role: "owner")
        eligibility = Eligibility.new(@household)
        latest = requests.order(id: :desc).first
        { household_id: @household.id, cohort_id: @membership&.cohort_id, financial_generation: @household.financial_generation,
          available: owner, owner_required: !owner, setup_complete: HouseholdFinance::SetupStatus.new(@household).complete?,
          self_restart_available: owner && eligibility.available?, blockers: eligibility.blockers,
          latest_request: latest && Serializer.request(latest) }
      end
    end

    def create_request(reason:, share_metadata:, idempotency_key:)
      raise Error, "Choose a setup help reason." unless SetupSupportRequest::REASONS.key?(reason)
      raise Error, "Confirm sharing this request's purpose and status with support." unless share_metadata == true
      key = idempotency_key.to_s.strip
      raise Error, "Idempotency-Key is required and must be at most 200 characters." unless key.present? && key.length <= 200
      digest = Digest::SHA256.hexdigest(JSON.generate(reason: reason, share_metadata: true, cohort_id: @membership&.cohort_id))
      @household.with_lock do
        HouseholdFinance::FinancialGenerationGuard.request!(@household)
        Access.participant!(@household, user: @user, cohort_membership: @membership, owner: true)
        retire_outdated_requests!
        existing = SetupHelpRequestKey.find_by(household: @household, user: @user, idempotency_key: key)
        if existing
          raise Conflict, "This request identity was already used for different setup help. Nothing changed." unless existing.request_fingerprint == digest
          record = requests.find(existing.setup_support_request_id)
          Access.participant!(@household, user: @user, cohort_membership: @membership, owner: true, request: record)
        else
          record = requests.where(status: SetupSupportRequest::ACTIVE).order(:id).first
          unless record
            record = @household.setup_support_requests.create!(requested_by_user: @user, cohort_id: @membership&.cohort_id,
              participant_membership_id: @membership&.id, participant_membership_started_at: @membership&.created_at, reason: reason)
            audit!(record, "requested")
          end
          Access.participant!(@household, user: @user, cohort_membership: @membership, owner: true, request: record)
          SetupHelpRequestKey.create!(household: @household, user: @user, setup_support_request: record, idempotency_key: key, request_fingerprint: digest)
        end
        { request: Serializer.request(record), setup_help: status }
      end
    end

    def cancel_request(id:, expected_lock_version:)
      @household.with_lock do
        record = own_request!(id)
        check_version!(record, expected_lock_version)
        if SetupSupportRequest::ACTIVE.include?(record.status)
          HouseholdFinance::FinancialRestart::Core.new(@household, user: @user).cancel_review!(record.financial_restart_review) if record.financial_restart_review
          record.update!(status: "canceled")
          audit!(record, "canceled")
        elsif record.status != "canceled"
          raise Error, "This request has already finished. Nothing changed."
        end
        { request: Serializer.request(record), setup_help: status }
      end
    end

    def reopen_request(id:, expected_lock_version:)
      @household.with_lock do
        record = own_request!(id)
        check_version!(record, expected_lock_version)
        raise Error, "Only a prepared request can be reopened. Nothing changed." unless record.status == "ready"
        HouseholdFinance::FinancialRestart::Core.new(@household, user: @user).cancel_review!(record.financial_restart_review) if record.financial_restart_review
        record.update!(status: "in_review", financial_restart_review: nil, prepared_by_user: nil)
        audit!(record, "reopened")
        { request: Serializer.request(record), setup_help: status }
      end
    end

    def own_request!(id)
      Access.participant!(@household, user: @user, cohort_membership: @membership, owner: true)
      record = requests.find(id)
      Access.participant!(@household, user: @user, cohort_membership: @membership, owner: true, request: record)
      record
    end

    def requests
      @household.setup_support_requests.where(requested_by_user: @user, cohort_id: @membership&.cohort_id,
        participant_membership_id: @membership&.id, participant_membership_started_at: @membership&.created_at)
    end

    def retire_outdated_requests!
      @household.setup_support_requests.where(requested_by_user: @user, cohort_id: @membership&.cohort_id,
        status: SetupSupportRequest::ACTIVE).order(:id).each do |record|
        next if record.participant_membership_id == @membership&.id && record.participant_membership_started_at == @membership&.created_at
        HouseholdFinance::FinancialRestart::Core.new(@household, user: @user).cancel_review!(record.financial_restart_review) if record.financial_restart_review
        record.update!(status: "canceled")
        audit!(record, "retired", retirement_reason: "participant_membership_changed")
      end
    end
    private :retire_outdated_requests!


    def check_version!(record, value)
      raise Stale, "This setup help request changed. Refresh it before continuing. Nothing changed." unless value.is_a?(Integer) && value >= 0 && record.lock_version == value
    end

    def audit!(record, action, retirement_reason: nil)
      @household.household_audit_events.create!(user: @user, actor_type: "user", event_type: "setup_support.#{action}",
        auditable_type: "SetupSupportRequest", auditable_id: record.id, occurred_at: Time.current,
        metadata: { requested_by_user_id: record.requested_by_user_id, cohort_id: record.cohort_id, reason: record.reason, status: record.status,
          review_id: record.financial_restart_review_id, lock_version: record.lock_version, retirement_reason: retirement_reason }.compact)
    end
  end
end
