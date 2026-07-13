module PlaidIntegration
  class TransactionSync
    MAX_RESTARTS = 2

    def initialize(plaid_item)
      @plaid_item = plaid_item
    end

    def call
      raise Error, "This bank connection has been disconnected" unless plaid_item.connected?

      sync_accounts!
      sync_transactions!
      plaid_item.update!(status: "active", error_code: nil, error_message: nil, last_synced_at: Time.current, last_successful_update_at: Time.current)
      plaid_item
    rescue Error => e
      record_error!(e)
      raise
    end

    private

    attr_reader :plaid_item

    def sync_accounts!
      response = Client.safely do |client|
        client.accounts_get(Plaid::AccountsGetRequest.new(access_token: plaid_item.access_token))
      end
      seen = []
      Array(response.accounts).each do |account|
        seen << account.account_id
        record = plaid_item.plaid_accounts.find_or_initialize_by(plaid_account_id: account.account_id)
        balances = account.balances
        record.update!(
          persistent_account_id: account.respond_to?(:persistent_account_id) ? account.persistent_account_id : nil,
          name: account.name.to_s.first(160),
          official_name: account.official_name.to_s.first(160).presence,
          mask: account.mask.to_s.first(10).presence,
          account_type: account.type.to_s,
          account_subtype: account.subtype.to_s.presence,
          current_balance_cents: cents_or_nil(balances.current),
          available_balance_cents: cents_or_nil(balances.available),
          limit_balance_cents: cents_or_nil(balances.limit),
          iso_currency_code: balances.iso_currency_code,
          active: true,
          last_synced_at: Time.current
        )
      end
      plaid_item.plaid_accounts.where.not(plaid_account_id: seen).update_all(active: false, updated_at: Time.current)
    end

    def sync_transactions!
      starting_cursor = plaid_item.sync_cursor
      attempts = 0
      begin
        cursor = starting_cursor
        changes = { added: [], modified: [], removed: [] }
        loop do
          response = Client.safely do |client|
            client.transactions_sync(Plaid::TransactionsSyncRequest.new(access_token: plaid_item.access_token, cursor: cursor, count: 500))
          end
          changes[:added].concat(Array(response.added))
          changes[:modified].concat(Array(response.modified))
          changes[:removed].concat(Array(response.removed))
          cursor = response.next_cursor
          break unless response.has_more
        end
        persist_changes!(changes, cursor)
      rescue Error => e
        if e.code == "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION" && attempts < MAX_RESTARTS
          attempts += 1
          retry
        end
        raise
      end
    end

    def persist_changes!(changes, cursor)
      ApplicationRecord.transaction do
        (changes[:added] + changes[:modified]).each { |transaction| upsert_transaction!(transaction) }
        changes[:removed].each do |removed|
          plaid_item.plaid_transactions.find_by(plaid_transaction_id: removed.transaction_id)&.update!(removed_at: Time.current)
        end
        plaid_item.update!(sync_cursor: cursor)
      end
    end

    def upsert_transaction!(transaction)
      account = plaid_item.plaid_accounts.find_by!(plaid_account_id: transaction.account_id)
      category = transaction.respond_to?(:personal_finance_category) ? transaction.personal_finance_category : nil
      record = plaid_item.plaid_transactions.find_or_initialize_by(plaid_transaction_id: transaction.transaction_id)
      attributes = {
        plaid_account: account,
        pending_transaction_id: transaction.pending_transaction_id,
        name: transaction.name.to_s.first(160),
        merchant_name: transaction.merchant_name.to_s.first(160).presence,
        occurred_on: transaction.date,
        authorized_on: transaction.authorized_date,
        amount_cents: (BigDecimal(transaction.amount.to_s) * 100).round,
        pending: transaction.pending,
        primary_category: category&.primary,
        detailed_category: category&.detailed,
        payment_channel: transaction.payment_channel,
        iso_currency_code: transaction.iso_currency_code,
        removed_at: nil
      }
      record.assign_attributes(attributes)
      record.source_fingerprint = Digest::SHA256.hexdigest(attributes.slice(:pending_transaction_id, :name, :merchant_name, :occurred_on, :authorized_on, :amount_cents, :pending, :primary_category, :detailed_category).to_json)
      record.save!
    end

    def cents_or_nil(value)
      value.nil? ? nil : (BigDecimal(value.to_s) * 100).round
    end

    def record_error!(error)
      return unless plaid_item.persisted? && plaid_item.connected?

      status = error.code.to_s.start_with?("ITEM_LOGIN") ? "update_required" : "error"
      plaid_item.update_columns(status: status, error_code: error.code.to_s.first(80).presence, error_message: error.message.first(240), updated_at: Time.current)
    end
  end
end
