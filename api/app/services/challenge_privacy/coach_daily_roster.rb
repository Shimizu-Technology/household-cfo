module ChallengePrivacy
  # Operational metadata only. All private record reads remain in SharedReader.
  class CoachDailyRoster
    FILTERS = %w[all needs_help checked_in not_checked_in invited joined setup_done].freeze
    def initialize(cohort, user:)
      @cohort, @user = cohort, user
    end

    def call(search: nil, filter: nil, offset: nil)
      Access.staff!(@cohort, @user)
      filter = filter.presence || "all"
      raise ArgumentError, "Choose a people filter" unless FILTERS.include?(filter)
      offset = offset.present? ? Integer(offset, 10) : 0
      raise ArgumentError, "Choose a valid page" if offset.negative?
      rows = @cohort.cohort_memberships.where(role: "participant").includes(user: { household_memberships: :household }).map { |membership| person(membership) }
      rows.sort_by! { |row| [ row[:needs_help] ? 0 : 1, row[:participant][:name].downcase, row[:participant][:id] ] }
      counts = FILTERS.index_with { |key| rows.count { |row| matches?(row, key) } }
      query = search.to_s.strip.downcase
      rows.select! { |row| matches?(row, filter) && row[:participant][:name].downcase.include?(query) }
      { program_type: @cohort.savings_challenge_enabled? ? "savings" : "household", counts: counts,
        can_invite: @user.admin? || @cohort.coach_workspace.membership_for(@user)&.role == "owner",
        records: rows.slice(offset, 20) || [], next_offset: offset + 20 < rows.length ? offset + 20 : nil }
    end

    private
    def person(membership)
      user = membership.user
      base = { participant: { id: user.id, name: user.full_name.presence || user.email }, enrollment_id: nil,
        membership_status: user.revoked? ? "revoked" : user.invitation_accepted? ? "joined" : "invited",
        participation_status: "not_enrolled", setup_status: "not_started", check_in: nil, help_requests: [], more_help_requests: false, setup_help: [], shared_items: [] }
      # Never create or resolve a staff financial workspace just to read a roster.
      household = user.household_memberships.min_by { |item| [ item.created_at, item.id ] }&.household
      base[:setup_status] = "complete" if household && HouseholdFinance::SetupStatus.new(household).complete?
      SetupSupportRequest.where(cohort: @cohort, requested_by_user: user, status: SetupSupportRequest::ACTIVE).order(:id).each do |request|
        request.household.with_lock do
          SetupHelp::Access.staff!(request, user: @user)
          base[:setup_help] << { id: request.id, reason: request.reason, status: request.status }
        end
      rescue SetupHelp::Denied
        next
      end
      enrollment = SavingsEnrollment.find_by(cohort: @cohort, user: user) if @cohort.savings_challenge_enabled?
      if enrollment
        begin
          reader = SharedReader.new(enrollment, user: @user)
          basic = reader.basic
          base.merge!(basic)
          # Open help must not disappear behind the first page of resolved requests.
          base[:help_requests] = ChallengeSupportTicket.where(savings_enrollment: enrollment, recipient_user: @user).where.not(status: "resolved")
            .order(:id).map { |ticket| { id: ticket.id, status: ticket.status, issue_kind: ticket.issue_kind } }
          # A sharing hint contains only its kind, never record identities or
          # contents. The focused panel still rechecks the full release and grant
          # policy through SharedReader before offering any private read.
          grants = ChallengePrivacyGrant.where(savings_enrollment: enrollment, recipient_user: @user).select(&:active?)
          supports = ChallengeSupportAccess.where(savings_enrollment: enrollment, recipient_user: @user).select(&:active?)
          refs = grants.select { |grant| grant.kind == "selected_details" }.flat_map(&:selected_records) + supports.flat_map(&:selected_records)
          base[:shared_items] = refs.map { |ref| ref.fetch("record_type") }.uniq
          base[:shared_items] << "summary" if grants.any? { |grant| grant.kind == "coach_summary" }
        rescue Access::Denied, SavingsChallenge::AccessPolicy::Unavailable
          # Stale enrollment or unavailable sharing never bypasses its existing guard.
        end
      end
      base[:needs_help] = base.values_at(:setup_help, :help_requests, :shared_items).any?(&:any?)
      base
    end

    def matches?(row, filter)
      case filter
      when "all" then true
      when "needs_help" then row[:needs_help]
      when "checked_in" then row.dig(:check_in, :completed) == true
      when "not_checked_in" then row.dig(:check_in, :completed) == false
      when "invited", "joined" then row[:membership_status] == filter
      when "setup_done" then row[:setup_status] == "complete"
      end
    end
  end
end
