module Api
  class PlaidWebhooksController < ApplicationController
    def create
      raw_body = request.raw_post
      PlaidIntegration::WebhookVerifier.new(token: request.headers["Plaid-Verification"], body: raw_body).verify!
      payload = JSON.parse(raw_body)
      item = PlaidItem.connected.find_by(plaid_item_id: payload["item_id"])
      PlaidTransactionSyncJob.perform_later(item.id) if item && payload["webhook_type"] == "TRANSACTIONS"
      head :no_content
    rescue PlaidIntegration::Error, JSON::ParserError
      head :unauthorized
    end
  end
end
