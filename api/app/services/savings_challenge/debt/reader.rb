module SavingsChallenge
  module Debt
    class Reader
      def initialize(enrollment, user:)
        @enrollment, @user = enrollment, user
      end

      def call
        private_read { comparison }
      end

      def records(kind:, cursor: nil)
        private_read do
          scope = case kind
          when "cards" then SavingsDebtCard.where(savings_enrollment: @enrollment)
          when "drafts" then SavingsDebtDraft.where(savings_enrollment: @enrollment)
          when "versions" then SavingsDebtVersion.where(savings_enrollment: @enrollment)
          else raise ArgumentError, "Choose cards, drafts or versions"
          end
          rows = scope.where("id > ?", cursor.nil? ? 0 : Inputs.id!(cursor)).order(:id).limit(51).to_a
          { records: rows.first(50).map { |record| self.class.record(record) }, next_cursor: rows.length > 50 ? rows[49].id : nil, actor_scope: actor_scope, enrollment_id: @enrollment.id, cohort_id: @enrollment.cohort_id }
        end
      end

      def candidates(cursor: nil)
        private_read do
          rows = SourceMapping.new(@enrollment.household).candidates.select { |row| cursor.nil? || row[:source_account_identity_version_id] > Inputs.id!(cursor) }.first(51)
          { records: rows.first(50), next_cursor: rows.length > 50 ? rows[49][:source_account_identity_version_id] : nil, actor_scope: actor_scope, enrollment_id: @enrollment.id, cohort_id: @enrollment.cohort_id }
        end
      end

      def self.record(record)
        case record
        when SavingsDebtCard
          record.attributes.slice("id", "savings_enrollment_id", "lock_version", "current_version_id", "source_tracked_account_id").merge("current_version" => record.current_version && self.record(record.current_version))
        when SavingsDebtDraft, SavingsDebtVersion
          record.attributes.except("created_at", "updated_at")
        else raise ArgumentError, "Unsupported optional card record"
        end
      end

      def self.authorize!(enrollment, user:)
        AccessPolicy.new(household: enrollment.household, user: user, cohort: enrollment.cohort.reload, enrollment: enrollment, lock: true).call!
        CohortReleases::OperationAccess.require!(household: enrollment.household, user: user, key: "savings.debt.stage", cohort: enrollment.cohort)
      end

      private

      def private_read
        ApplicationRecord.transaction do
          @enrollment.household.lock!
          @enrollment.reload
          self.class.authorize!(@enrollment, user: @user)
          result = yield
          self.class.authorize!(@enrollment, user: @user)
          result
        end
      end

      def actor_scope = { user_id: @user.id, household_id: @enrollment.household_id }

      def comparison
        mapping = SourceMapping.new(@enrollment.household)
        cards = SavingsDebtCard.where(savings_enrollment: @enrollment).includes(:current_version).order(:id).filter_map do |card|
          version = card.current_version
          next unless version
          terms = version.terms
          stale = !mapping.current?(version)
          reasons = []
          reasons << "source_terms_stale" if stale
          reasons << "archived" if terms["status"] == "archived"
          reasons << "paid_off" if terms["balance_cents"] == 0 || terms["status"] == "paid_off"
          reasons << "balance_unknown" if terms["balance_cents"].nil?
          reasons << "apr_unknown" if terms["apr_bps"].nil?
          reasons << "minimum_unknown" if terms["minimum_payment_cents"].nil?
          promotional = %w[promotional_apr_bps promotional_expires_on post_promo_apr_bps].any? { |key| !terms[key].nil? }
          reasons << "promotional_terms_need_review" if promotional
          reasons << "multiple_or_partial_rates" if terms.fetch("rate_segments").any?
          row = { card_id: card.id, version_id: version.id, label: terms.fetch("label"), terms: terms, source_stale: stale, qualifications: reasons,
            promotional_expired: terms["promotional_expires_on"] && Date.iso8601(terms["promotional_expires_on"]) < @enrollment.local_today }
          eligible = !stale && terms["status"] == "active" && terms["balance_cents"]&.positive?
          row.merge(snowball_eligible: !!eligible, avalanche_eligible: !!(eligible && terms["apr_bps"] && !promotional && terms.fetch("rate_segments").empty?))
        end
        known = cards.reject { |row| row[:source_stale] || row[:terms]["status"] == "archived" }.filter_map { |row| row[:terms]["balance_cents"] }
        { enrollment_id: @enrollment.id, cohort_id: @enrollment.cohort_id, actor_scope: actor_scope, local_today: @enrollment.local_today.iso8601, cards: cards,
          portfolio_complete: false, known_balance_subtotal_cents: known.empty? ? nil : known.sum,
          unknown_balance_count: cards.count { |row| row[:terms]["balance_cents"].nil? }, stale_card_count: cards.count { |row| row[:source_stale] },
          snowball_order: cards.select { |row| row[:snowball_eligible] }.sort_by { |row| [ row[:terms]["balance_cents"], row[:card_id] ] }.map { |row| row[:card_id] },
          avalanche_order: cards.select { |row| row[:avalanche_eligible] }.sort_by { |row| [ -row[:terms]["apr_bps"], row[:card_id] ] }.map { |row| row[:card_id] },
          extra_payment_cents: nil, payoff_date: nil, savings_credit_cents: nil,
          qualifications: [ "Only your currently approved optional cards are represented; complete household debt coverage is not established.",
            "Snowball is a known-balance order only. Avalanche excludes unknown balances, unknown APRs, promotions and separate-rate segments.",
            "Income, essentials, required payments and liquidity have not been verified here. No extra-payment amount or payoff date is recommended.",
            "Card payments and debt-balance changes do not create challenge savings." ] }
      end
    end
  end
end
