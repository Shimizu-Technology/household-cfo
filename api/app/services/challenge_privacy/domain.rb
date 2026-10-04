module ChallengePrivacy
  class Domain
    attr_reader :household, :user
    def initialize(household, user:) = (@household, @user = household, user)
    def enrollment(id) = SavingsEnrollment.where(household: household, user: user).find(id)
    def authorize!(record) = Access.participant!(household, user, record)
    def scope(record) = { household: household, savings_enrollment: record, participant_user_id: record.user_id }
    def digest(value) = HouseholdFinance::Operations::PreparedOperation.fingerprint(value)

    def normalize(action, raw)
      input = raw.to_h.deep_symbolize_keys
      record = enrollment(id!(input.fetch(:enrollment_id)))
      authorize!(record)
      case action
      when "consent"
        keys!(input, %i[enrollment_id kind recipient_user_id granted selected_records expires_at policy_version expected_grant_id expected_lock_version])
        kind = input.fetch(:kind).to_s
        raise ArgumentError, "Choose a separate supported sharing purpose" unless ChallengePrivacyGrant::KINDS.include?(kind)
        granted = boolean!(input.fetch(:granted))
        recipient = nullable_id(input.fetch(:recipient_user_id))
        raise ArgumentError, "Sponsor consent has no individual recipient" if kind == "sponsor_aggregate" && recipient
        raise ArgumentError, "Choose an exact coach recipient" if kind != "sponsor_aggregate" && !recipient
        records = RecordSelector.new(record).call(input.fetch(:selected_records))
        raise ArgumentError, "Only selected-details consent may include records" if kind != "selected_details" && records.any?
        raise ArgumentError, "Select exact records for detailed sharing" if granted && kind == "selected_details" && records.empty?
        expiry = nullable_time(input.fetch(:expires_at))
        raise ArgumentError, "Detailed sharing needs an expiry" if granted && kind == "selected_details" && expiry.nil?
        raise ArgumentError, "Review the current privacy policy" unless input.fetch(:policy_version) == "challenge_privacy_v1"
        input.merge(kind: kind, recipient_user_id: recipient, granted: granted, selected_records: records, expires_at: expiry,
          expected_grant_id: nullable_id(input[:expected_grant_id]), expected_lock_version: nonnegative!(input[:expected_lock_version]))
      when "ticket"
        keys!(input, %i[enrollment_id recipient_user_id issue_kind message selected_records])
        raise ArgumentError, "Choose a support purpose" unless input[:issue_kind].in?(%w[technical coaching access other])
        input.merge(recipient_user_id: id!(input[:recipient_user_id]), message: text!(input[:message]), selected_records: RecordSelector.new(record).call(input[:selected_records]))
      when "support_grant"
        keys!(input, %i[enrollment_id ticket_id recipient_user_id selected_records reason expires_at expected_ticket_lock_version])
        input.merge(ticket_id: id!(input[:ticket_id]), recipient_user_id: id!(input[:recipient_user_id]),
          selected_records: RecordSelector.new(record).call(input[:selected_records]), reason: text!(input[:reason]),
          expires_at: time!(input[:expires_at]), expected_ticket_lock_version: nonnegative!(input[:expected_ticket_lock_version]))
      when "support_revoke"
        keys!(input, %i[enrollment_id access_id expected_lock_version])
        input.merge(access_id: id!(input[:access_id]), expected_lock_version: nonnegative!(input[:expected_lock_version]))
      when "source_authorize"
        keys!(input, %i[enrollment_id document_import_id disclosure_version expected_expires_at expected_use_id expected_lock_version])
        input.merge(document_import_id: id!(input[:document_import_id]), expected_use_id: nullable_id(input[:expected_use_id]), expected_lock_version: nonnegative!(input[:expected_lock_version]))
      when "source_revoke"
        keys!(input, %i[enrollment_id document_import_id expected_affected_uses_digest])
        input.merge(document_import_id: id!(input[:document_import_id]))
      else raise ArgumentError, "Unsupported privacy operation"
      end
    rescue KeyError, TypeError
      raise ArgumentError, "Privacy approval is missing required fields"
    end

    def snapshot(action, input)
      record = enrollment(input[:enrollment_id])
      authorize!(record)
      case action
      when "consent"
        grant = grant_for(record, input)
        if input[:granted]
          Access.participant!(household, user, record, active: true)
          Access.staff!(record, User.find(input[:recipient_user_id])) if input[:recipient_user_id]
          validate_expiry!(input[:expires_at], maximum: 366.days) if input[:expires_at]
          RecordSelector.new(record).call(input[:selected_records])
        end
        state(grant)
      when "ticket"
        Access.participant!(household, user, record, active: true)
        Access.staff!(record, User.find(input[:recipient_user_id]))
        RecordSelector.new(record).call(input[:selected_records])
        { enrollment_id: record.id, recipient_user_id: input[:recipient_user_id] }
      when "support_grant"
        Access.participant!(household, user, record, active: true)
        ticket = tickets(record).find(input[:ticket_id])
        Access.staff!(record, User.find(input[:recipient_user_id]))
        raise ArgumentError, "Support recipient must match the reviewed ticket" unless ticket.recipient_user_id == input[:recipient_user_id]
        raise ArgumentError, "Select exact support records" if input[:selected_records].empty?
        validate_expiry!(input[:expires_at], maximum: 24.hours)
        RecordSelector.new(record).call(input[:selected_records])
        state(ticket)
      when "support_revoke" then state(accesses(record).find(input[:access_id]))
      when "source_authorize", "source_revoke"
        source = household.financial_document_imports.find(input[:document_import_id])
        retention = SourceRetention.new(household, user: user)
        description = retention.describe(source)
        if action == "source_authorize"
          Access.participant!(household, user, record, active: true)
          use = FinancialSourceUse.find_by(financial_document_import: source, savings_enrollment: record)
          { source: source.attributes.slice("id", "source_deleted_at", "s3_key").except("s3_key").merge("source_available" => source.source_available?), use: state(use), uses: description[:affected_uses] }
        else
          raise ArgumentError, "Review every affected source use before global deletion" unless input[:expected_affected_uses_digest] == digest(description[:affected_uses])
          { source_id: source.id, source_deleted_at: source.source_deleted_at, uses: description[:affected_uses] }
        end
      end
    end

    def execute(action, input)
      ApplicationRecord.transaction do
        household.lock!
        execute_locked(action, normalize(action, input))
      end
    end

    def execute_locked(action, input)
      record = enrollment(input[:enrollment_id])
      authorize!(record)
      snapshot(action, input)
      values = case action
      when "consent"
        grant = grant_for(record, input)
        check!(grant, input[:expected_grant_id], input[:expected_lock_version])
        grant ||= ChallengePrivacyGrant.new(scope(record).merge(kind: input[:kind], recipient_user_id: input[:recipient_user_id]))
        grant.update!(granted: input[:granted], selected_records: input[:selected_records], expires_at: input[:expires_at], policy_version: input[:policy_version])
        grant
      when "ticket"
        ChallengeSupportTicket.create!(scope(record).merge(input.slice(:recipient_user_id, :issue_kind, :message, :selected_records)))
      when "support_grant"
        ticket = tickets(record).lock.find(input[:ticket_id])
        check!(ticket, ticket.id, input[:expected_ticket_lock_version])
        ticket.update!(status: "triaged")
        ChallengeSupportAccess.create!(scope(record).merge(challenge_support_ticket: ticket, recipient_user_id: input[:recipient_user_id], selected_records: input[:selected_records], reason: input[:reason], expires_at: input[:expires_at]))
      when "support_revoke"
        access = accesses(record).lock.find(input[:access_id])
        check!(access, access.id, input[:expected_lock_version])
        access.update!(revoked_at: access.revoked_at || Time.current)
        access
      when "source_authorize"
        source = household.financial_document_imports.lock.find(input[:document_import_id])
        use = FinancialSourceUse.find_by(financial_document_import: source, savings_enrollment: record)
        check!(use, input[:expected_use_id], input[:expected_lock_version])
        SourceRetention.new(household, user: user).authorize!(source, record, disclosure_version: input[:disclosure_version], expected_expires_at: input[:expected_expires_at])
      when "source_revoke"
        source = household.financial_document_imports.lock.find(input[:document_import_id])
        SourceRetention.new(household, user: user).revoke_all!(source)[:source]
      end
      ChallengePrivacyEvent.create!(scope(record).merge(actor_user: user, action: action, subject_type: values.class.name, subject_id: values.id, approved_values: input.except(:enrollment_id), created_at: Time.current))
    end
    private :execute_locked

    def grant_for(record, input) = ChallengePrivacyGrant.find_by(savings_enrollment: record, kind: input[:kind], recipient_user_id: input[:recipient_user_id])
    def tickets(record) = ChallengeSupportTicket.where(savings_enrollment: record)
    def accesses(record) = ChallengeSupportAccess.where(savings_enrollment: record)
    def state(record) = record ? { id: record.id, lock_version: record.lock_version, digest: digest(record.attributes) } : { id: nil, lock_version: 0 }
    def check!(record, id, lock)
      raise HouseholdFinance::Operations::Base::StaleOperation, "This privacy choice changed; review it again" unless record&.id == id && (record&.lock_version || 0) == lock
    end
    def keys!(input, keys) = (raise ArgumentError, "Unexpected or missing privacy fields" unless input.keys.sort == keys.sort)
    def id!(value) = (value if value.is_a?(Integer) && value.positive?) || raise(ArgumentError, "Use an exact positive record identity")
    def nullable_id(value) = value.nil? ? nil : id!(value)
    def nonnegative!(value) = (value if value.is_a?(Integer) && value >= 0) || raise(ArgumentError, "Use an exact lock version")
    def boolean!(value) = ([ true, false ].include?(value) ? value : raise(ArgumentError, "Use an explicit sharing choice"))
    def text!(value)
      raise ArgumentError, "Review concise text of at most 500 characters" unless value.is_a?(String) && value.squish.length.between?(1, 500)
      value.squish
    end
    def time!(value)
      raise ArgumentError, "Use an exact timestamp with timezone" unless value.is_a?(String) && value.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
      Time.iso8601(value).iso8601
    rescue ArgumentError
      raise ArgumentError, "Use an exact timestamp with timezone"
    end
    def nullable_time(value) = value.nil? ? nil : time!(value)
    def validate_expiry!(value, maximum:)
      expiry = Time.iso8601(value)
      raise ArgumentError, "Sharing expiry must be in the reviewed future window" unless expiry > Time.current && expiry <= Time.current + maximum
    end
  end
end
