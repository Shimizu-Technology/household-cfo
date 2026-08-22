module PlaidIntegration
  class ItemWebhookHandler
    REAUTHENTICATION_CODES = %w[
      NEW_ACCOUNTS_AVAILABLE
      PENDING_DISCONNECT
      PENDING_EXPIRATION
      USER_PERMISSION_REVOKED
    ].freeze

    def initialize(item:, payload:)
      @item = item
      @payload = payload
    end

    def call
      return item unless item.connected?

      case webhook_code
      when "ERROR"
        handle_error!
      when *REAUTHENTICATION_CODES
        require_update!(webhook_code)
      when "LOGIN_REPAIRED"
        restore_item!
      when "USER_ACCOUNT_REVOKED"
        revoke_account!
      end

      item
    end

    private

    attr_reader :item, :payload

    def webhook_code
      payload["webhook_code"].to_s
    end

    def handle_error!
      code = payload.dig("error", "error_code").to_s.first(80).presence || "ITEM_ERROR"
      if code.start_with?("ITEM_LOGIN") || code == "INVALID_CREDENTIALS"
        require_update!(code)
      else
        item.update_columns(
          status: "error",
          error_code: code,
          error_message: "Plaid reported a bank connection error. Try syncing again or contact support.",
          updated_at: Time.current
        )
      end
    end

    def require_update!(code)
      item.update_columns(
        status: "update_required",
        error_code: code.to_s.first(80),
        error_message: "This bank connection needs attention. Reconnect it to keep transactions up to date.",
        updated_at: Time.current
      )
    end

    def restore_item!
      item.update_columns(status: "active", error_code: nil, error_message: nil, updated_at: Time.current)
      PlaidTransactionSyncJob.perform_later(item.id)
    end

    def revoke_account!
      account_id = payload["account_id"].to_s
      return if account_id.blank?

      ApplicationRecord.transaction do
        account = item.plaid_accounts.find_by(plaid_account_id: account_id)
        if account
          PendingDraftCleaner.new(household: item.household, transactions: account.plaid_transactions).call
          account.destroy!
        end
        require_update!(webhook_code)
      end
    end
  end
end
