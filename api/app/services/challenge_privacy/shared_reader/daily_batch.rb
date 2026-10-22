module ChallengePrivacy
  class SharedReader
    # A request-local, locked snapshot. This exposes operational metadata only;
    # summary, selected records and messages still use the audited single reader.
    class DailyBatch
      def initialize(cohort, user:)
        @cohort, @actor = cohort, user
      end

      def call
        ApplicationRecord.transaction do
          enrollments = SavingsEnrollment.where(cohort: @cohort).order(:id).to_a
          households = Household.where(id: enrollments.map(&:household_id)).order(:id).lock.index_by(&:id)
          @cohort = Cohort.find(@cohort.id)
          Access.staff!(@cohort, @actor)
          # Reload after acquiring the same household lock as the single reader.
          enrollments = SavingsEnrollment.where(id: enrollments.map(&:id)).order(:id).to_a
          users = User.where(id: enrollments.map(&:user_id)).order(:id).lock.index_by(&:id)
          members = @cohort.cohort_memberships.where(role: "participant").order(:id).lock.index_by(&:user_id)
          owners = HouseholdMembership.where(household_id: households.keys, user_id: users.keys).order(:id).lock.to_a.index_by { |o| [ o.household_id, o.user_id ] }
          enrollments.select! do |e|
            u, m = users[e.user_id], members[e.user_id]
            u&.participant? && !u.revoked? && m && m.id == e.accepted_cohort_membership_id && m.created_at == e.membership_started_at &&
              owners[[ e.household_id, e.user_id ]]&.role.in?(%w[owner partner])
          end
          load_runtime(members.values)
          ids = enrollments.map(&:id)
          tickets = ChallengeSupportTicket.where(savings_enrollment_id: ids, recipient_user: @actor).order(:id).to_a.group_by(&:savings_enrollment_id)
          grants = ChallengePrivacyGrant.where(savings_enrollment_id: ids, recipient_user: @actor).to_a.group_by(&:savings_enrollment_id)
          supports = ChallengeSupportAccess.where(savings_enrollment_id: ids, recipient_user: @actor).to_a.group_by(&:savings_enrollment_id)
          attendance = attendance_for(enrollments.select { |e| runtime_allowed?(e, members.fetch(e.user_id)) && operation_allowed?(members.fetch(e.user_id), "savings.daily.check_in.save") })
          enrollments.to_h do |e|
            current = runtime_allowed?(e, members.fetch(e.user_id))
            financial = current && operation_allowed?(members.fetch(e.user_id), "privacy.consent.set")
            active_grants = financial ? Array(grants[e.id]).select(&:active?) : []
            active_supports = financial ? Array(supports[e.id]).select(&:active?) : []
            refs = active_grants.select { |g| g.kind == "selected_details" }.flat_map(&:selected_records) + active_supports.flat_map(&:selected_records)
            hints = refs.map { |r| r.fetch("record_type") }.uniq
            hints << "summary" if active_grants.any? { |g| g.kind == "coach_summary" }
            on = e.local_today
            active = e.status == "active" && on.between?(e.starts_on, e.ends_on)
            available = current && operation_allowed?(members.fetch(e.user_id), "savings.daily.check_in.save")
            check_in = { local_on: on.iso8601, completed: active && available ? attendance.fetch(e.id, false) : nil,
              availability: !active ? "outside_active_window" : available ? "available" : "unavailable" }
            help = Array(tickets[e.id]).reject { |t| t.status == "resolved" }.map { |t| { id: t.id, status: t.status, issue_kind: t.issue_kind } }
            [ e.user_id, { enrollment_id: e.id, participation_status: e.status,
              setup_status: e.current_accepted_plan_version_id ? "plan_reviewed" : "plan_pending",
              check_in: check_in, help_requests: help, more_help_requests: Array(tickets[e.id]).length > 50, shared_items: hints } ]
          end
        end
      end

      private

      # Match ParticipantRuntimeResolver: the latest exposure is tied to the
      # exact membership incarnation; otherwise the cohort's active release wins.
      def load_runtime(members)
        exposures = CohortReleaseExposure.where(cohort_id: @cohort.id, cohort_membership_id: members.map(&:id)).order(:id).to_a
        @exposures = exposures.group_by(&:cohort_membership_id)
        ids = exposures.map(&:cohort_release_id) + [ @cohort.active_cohort_release_id ]
        @releases = CohortRelease.where(id: ids).includes(:cohort, :cohort_experience_configuration, :cohort_experience_version, :workspace_brand_version, :coach_persona_version).index_by(&:id)
        @runtime_valid = {}
      end

      def release_for(member)
        exposure = Array(@exposures[member.id]).reverse.find { |x| x.user_id == member.user_id && x.membership_started_at == member.created_at }
        @releases[exposure ? exposure.cohort_release_id : @cohort.active_cohort_release_id]
      end

      def runtime_allowed?(enrollment, member)
        release = release_for(member)
        accepted = @accepted_releases ||= CohortRelease.where(id: SavingsEnrollment.where(cohort: @cohort).select(:accepted_cohort_release_id)).pluck(:id, :cohort_id).to_h
        @cohort.savings_challenge_enabled? && !@cohort.savings_challenge_release_hold? && @cohort.status.in?(%w[enrolling active completed]) &&
          enrollment.status.in?(%w[active completed]) && accepted[enrollment.accepted_cohort_release_id] == @cohort.id && valid_release?(release)
      end

      def valid_release?(release)
        return false unless release && release.cohort_id == @cohort.id && release.coach_workspace_id == @cohort.coach_workspace_id
        return @runtime_valid[release.id] if @runtime_valid.key?(release.id)
        @runtime_valid[release.id] = SavingsChallenge::AccessPolicy.release_supports_challenge?(release) && begin
          # RuntimePersona validates the sealed persona even for metadata reads.
          if release.persona_mode == "published_version"
            version = release.coach_persona_version
            raise ActiveRecord::RecordNotFound unless version && release.coach_persona_id == version.coach_persona_id
            @persona_valid ||= {}
            unless @persona_valid[version.id]
              Mia::RuntimePersona.new(version)
              @persona_valid[version.id] = true
            end
          end
          true
        end
      rescue ArgumentError, KeyError, ActiveRecord::RecordNotFound, Mia::PersonaSchema::InvalidConfiguration
        @runtime_valid[release.id] = false
      end

      def operation_allowed?(member, key)
        release = release_for(member)
        valid_release?(release) && release.tool_registry_snapshot.fetch("operations").include?(
          { "key" => key, "version" => HouseholdFinance::Operations::Registry.fetch(key)::VERSION })
      end

      def attendance_for(enrollments)
        ids = enrollments.map(&:id)
        # Enrollment currently permits one timezone. Use each enrollment's local
        # date below rather than assuming the database/server calendar.
        dates = enrollments.map(&:local_today).uniq
        heads = SavingsDailyCheckIn.where(savings_enrollment_id: ids, local_on: dates).includes(:current_version).to_a.index_by { |h| [ h.savings_enrollment_id, h.local_on ] }
        purchases = SavingsDailyPurchaseVersion.joins(:savings_daily_purchase).where(savings_enrollment_id: ids, purchased_on: dates, disposition: "purchase")
          .where("savings_daily_purchase_versions.id = savings_daily_purchases.current_version_id").includes(household_transaction: :transaction_splits).to_a
        projections = SourceProjectionRevision.where(household_id: enrollments.map(&:household_id), replacement_transaction_id: purchases.map(&:household_transaction_id), action: %w[create replace])
          .includes(source_review_version: [ :source_review_head, :financial_source_event, { source_account_identity_version: :source_account_review_head } ]).order(:id).to_a.group_by(&:replacement_transaction_id)
        purchases = purchases.group_by { |p| [ p.savings_enrollment_id, p.purchased_on ] }
        enrollments.to_h do |e|
          head = heads[[ e.id, e.local_today ]]
          v = head&.current_version
          daily = Array(purchases[[ e.id, e.local_today ]])
          valid = v && v.savings_daily_check_in_id == head.id && v.savings_enrollment_id == e.id && v.approved_by_user_id == e.user_id &&
            v.approved_at && v.version_number.positive? && v.spending_state.in?(%w[spending no_spend])
          valid &&= daily.all? { |p| canonical?(p, e, projections) } && !(v.spending_state == "no_spend" && daily.any?)
          [ e.id, !!valid ]
        end
      end

      # Same canonical facts checked by Daily::CanonicalPurchase, using the bulk
      # snapshot. No purchase facts leave this reader.
      def canonical?(purchase, enrollment, projections)
        t = purchase.household_transaction
        dates = [ t.occurred_on ]
        if t.financial_source_event_id
          projection = Array(projections[t.id]).select { |p| p.household_id == enrollment.household_id }.last
          v = projection&.source_review_version
          return false unless v && v.household_id == enrollment.household_id && v.financial_source_event.id == t.financial_source_event_id &&
            v.source_review_head.approved_version_id == v.id && v.source_account_identity_version.source_account_review_head.approved_version_id == v.source_account_identity_version_id &&
            v.expense? && v.purchase_amount_cents == t.total_amount_cents && v.merchant == t.merchant && v.posted_on == t.occurred_on
          dates << v.authorized_on
        end
        t.status.in?(%w[confirmed reconciled]) && t.total_amount_cents == purchase.amount_cents && t.merchant == purchase.merchant && dates.include?(purchase.purchased_on) &&
          t.transaction_splits.map { |s| [ s.budget_category_id, s.amount_cents ] }.sort == purchase.splits.map { |s| [ s.fetch("budget_category_id"), s.fetch("amount_cents") ] }.sort
      end
    end
  end
end
