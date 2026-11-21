module HouseholdFinance
  # Offers to set a household account's balance (or a card's amount owed) from
  # the closing balance on that account's latest approved, complete statement.
  # Nothing here changes money: the participant approves each offer through
  # account.statement_balance.apply or debt.statement_balance.apply.
  #
  # Rules:
  # - Only the latest approved complete statement period counts. If nothing for
  #   that period printed a closing balance (only a spreadsheet or phone
  #   screenshots), there is no offer; an older statement's balance is never
  #   offered in its place.
  # - A balance that already came from this statement or a newer one, or a
  #   balance she saved as of the statement date or later, is never replaced.
  #   A manual edit after a statement therefore wins until a newer statement.
  # - A card's closing balance is what she owes. A credit balance (negative) is
  #   not offered as a debt.
  class StatementBalanceOffers
    ASSET_ACCOUNT_TYPES = %w[checking savings emergency_fund other].freeze
    CARD_DEBT_TYPES = %w[credit_card other].freeze
    METADATA_KEY = "statement_balance".freeze

    def initialize(household)
      @household = household
      @approval_cache = {}
    end

    def call
      tracked_accounts.filter_map { |tracked| offer_for(tracked) }
    end

    def find(tracked_account_id)
      tracked = tracked_accounts.find { |row| row.id == tracked_account_id.to_i }
      tracked && offer_for(tracked)
    end

    # The provenance written onto an account or debt when she approves an offer.
    def self.provenance(offer)
      { "tracked_account_id" => offer.fetch(:tracked_account_id), "identity_version_id" => offer.fetch(:identity_version_id),
        "revision_approval_id" => offer.fetch(:revision_approval_id), "period_end_on" => offer.fetch(:as_of_on),
        "closing_balance_cents" => offer.fetch(:balance_cents), "statement_label" => offer.fetch(:statement_label) }
    end

    def self.linked_tracked_account_id(record)
      record.source_metadata.is_a?(Hash) ? record.source_metadata.dig(METADATA_KEY, "tracked_account_id") : nil
    end

    private

    attr_reader :household

    def tracked_accounts
      @tracked_accounts ||= SourceTrackedAccount.current_picture.where(household: household).order(:id).to_a
    end

    def offer_for(tracked)
      statement = latest_statement(tracked)
      return unless statement

      liability = tracked.account_basis == "liability"
      return if liability && (statement[:balance_cents].negative? || debt_portfolio.mode != "individual")

      offer = {
        tracked_account_id: tracked.id, kind: liability ? "debt" : "account", statement_label: tracked.label,
        identity_version_id: statement[:identity].id, revision_approval_id: statement[:approval].id,
        balance_cents: statement[:balance_cents], as_of_on: statement[:as_of_on]
      }
      linked = liability ? linked_debt(tracked) : linked_account(tracked)
      if linked
        return unless replaceable?(linked, offer)

        offer.merge!(target: target_row(linked), choices: [], can_add_new: false, new_label: nil)
      else
        compatible = (liability ? debt_choices(tracked) : account_choices(tracked)).select { |record| compatible?(record, offer) }
        suggested = suggestion(tracked, compatible)
        return if suggested && !replaceable?(suggested, offer)

        # An account whose saved balance is as new as this statement keeps it.
        choices = compatible.select { |record| replaceable?(record, offer) }

        new_label = tracked.label.to_s.squish.truncate(120, omission: "…")
        can_add_new = !label_taken?(new_label, liability)
        return if choices.empty? && !can_add_new

        offer.merge!(target: suggested && target_row(suggested), choices: choices.map { |record| target_row(record) },
          can_add_new: can_add_new, new_label: can_add_new ? new_label : nil, new_account_type: liability ? "credit_card" : new_account_type(tracked))
      end
      offer.merge(key: key_for(offer))
    end

    # The newest approved complete statement for this account, or nil when it
    # printed no single closing balance.
    def latest_statement(tracked)
      identities = current_identities.select { |identity| identity.source_tracked_account_id == tracked.id && identity.statement_facts["period_end_on"].present? }
      identities.group_by { |identity| identity.statement_facts["period_end_on"] }.sort_by { |period_end_on, _rows| period_end_on }.reverse_each do |period_end_on, rows|
        approved = rows.filter_map { |identity| (approval = complete_approval(identity)) && [ identity, approval ] }
        next if approved.empty?

        # A spreadsheet or screenshot for the same period prints no balance; it
        # neither supplies nor contradicts the statement's closing balance.
        printed = approved.reject { |identity, _approval| identity.statement_facts["closing_balance_cents"].nil? }
        return nil if printed.empty? || printed.map { |identity, _approval| identity.statement_facts["closing_balance_cents"] }.uniq.length != 1

        identity, approval = printed.min_by { |row, _approval| row.id }
        return { identity: identity, approval: approval, balance_cents: Integer(identity.statement_facts["closing_balance_cents"]), as_of_on: Date.iso8601(period_end_on).iso8601 }
      end
      nil
    rescue Date::Error, ArgumentError, TypeError
      nil
    end

    def current_identities
      @current_identities ||= SourceAccountIdentityVersion.where(household: household, source_tracked_account_id: tracked_accounts.map(&:id))
        .joins(:source_account_review_head).where("source_account_review_heads.approved_version_id = source_account_identity_versions.id")
        .includes(source_account_review_head: { financial_source_account: { financial_extraction_revision: :financial_document_import } }).to_a
    end

    # The statement's latest coverage approval must be complete and cover this
    # exact account version. Linking a transfer in a later file changes the
    # approval's row dependencies, not the balance printed on this statement.
    def complete_approval(identity)
      revision = identity.source_account_review_head.financial_source_account.financial_extraction_revision
      approval = @approval_cache.fetch(revision.id) { @approval_cache[revision.id] = latest_approval(revision) }
      approval if approval && approval.coverage_status == "complete" && Array(approval.account_version_ids).map(&:to_i).include?(identity.id)
    end

    def latest_approval(revision)
      import = revision.financial_document_import
      return unless import && import.financial_generation == household.financial_generation && import.metadata["source_accounting_revision_id"].to_i == revision.id

      latest_approvals[revision.id]
    end

    def latest_approvals
      @latest_approvals ||= begin
        ids = current_identities.map { |identity| identity.source_account_review_head.financial_source_account.financial_extraction_revision_id }.uniq
        SourceRevisionApproval.where(household: household, financial_extraction_revision_id: ids).order(:financial_extraction_revision_id, version_number: :desc)
          .group_by(&:financial_extraction_revision_id).transform_values(&:first)
      end
    end

    def linked_account(tracked)
      return household.accounts.active.find_by(id: tracked.account_id) if tracked.account_id

      active_accounts.find { |account| self.class.linked_tracked_account_id(account) == tracked.id }
    end

    def linked_debt(tracked)
      active_debts.find { |debt| self.class.linked_tracked_account_id(debt) == tracked.id }
    end

    def account_choices(tracked)
      active_accounts.select { |account| account.account_type.in?(ASSET_ACCOUNT_TYPES) && unlinked?(account, tracked) }
    end

    def debt_choices(tracked)
      active_debts.select { |debt| debt.debt_type.in?(CARD_DEBT_TYPES) && unlinked?(debt, tracked) }
    end

    def unlinked?(record, tracked)
      linked_id = self.class.linked_tracked_account_id(record)
      return linked_id == tracked.id if linked_id
      return true unless record.is_a?(::Account)

      tracked_accounts.none? { |other| other.account_id == record.id && other.id != tracked.id }
    end

    # The one account she most likely means: the same name, or the same last four digits.
    def suggestion(tracked, choices)
      exact = choices.select { |record| record.label.squish.casecmp?(tracked.label.to_s.squish) }
      return exact.first if exact.one?

      last4 = FinancialDocuments::SourceReview::AccountName.parts(tracked.label)[:last4]
      return unless last4

      matches = choices.select { |record| FinancialDocuments::SourceReview::AccountName.parts(record.label)[:last4] == last4 }
      matches.first if matches.one?
    end

    def compatible?(record, offer)
      return true unless record.is_a?(::Account) && offer[:balance_cents].negative?

      record.account_type.in?(::Account::SIGNED_BALANCE_TYPES)
    end

    def replaceable?(record, offer)
      return false unless compatible?(record, offer)

      applied = record.source_metadata.is_a?(Hash) ? record.source_metadata[METADATA_KEY] : nil
      return false if applied.is_a?(Hash) && applied["period_end_on"].to_s >= offer[:as_of_on]
      return true unless record.balance_known?
      return false if record.is_a?(::Account) && record.balance_as_of_on && record.balance_as_of_on.iso8601 >= offer[:as_of_on]

      record.balance_cents != offer[:balance_cents]
    end

    def label_taken?(label, liability)
      if liability
        active_debts.any? { |debt| debt.debt_type == "credit_card" && debt.label.casecmp?(label) }
      else
        active_accounts.any? { |account| account.label.casecmp?(label) }
      end
    end

    def new_account_type(tracked) = tracked.label.to_s.match?(/sav/i) ? "savings" : "checking"

    def target_row(record)
      if record.is_a?(::Account)
        { kind: "account", id: record.id, label: record.label, type: record.account_type,
          balance_cents: record.balance_known? ? record.balance_cents : nil, balance_as_of_on: record.balance_as_of_on&.iso8601 }
      else
        { kind: "debt", id: record.id, label: record.label, type: record.debt_type,
          balance_cents: record.balance_known? ? record.balance_cents : nil, balance_as_of_on: record.source_metadata.dig(METADATA_KEY, "period_end_on") }
      end
    end

    def key_for(offer)
      Operations::PreparedOperation.fingerprint(offer.slice(:tracked_account_id, :kind, :identity_version_id, :revision_approval_id, :balance_cents, :as_of_on))
    end

    def active_accounts = @active_accounts ||= household.accounts.active.order(:id).to_a
    def active_debts = @active_debts ||= household.debts.active.order(:id).to_a
    def debt_portfolio = @debt_portfolio ||= DebtPortfolio.new(household)
  end
end
