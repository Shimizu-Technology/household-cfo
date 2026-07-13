module PlaidIntegration
  class ItemConnector
    def initialize(household:, user:, public_token:, institution_id:, institution_name:)
      @household = household
      @user = user
      @public_token = public_token.to_s
      @institution_id = institution_id.to_s.presence
      @institution_name = institution_name.to_s.squish.presence
    end

    def call
      raise Error, "Plaid did not return a connection token" if public_token.blank?

      exchange = Client.safely do |client|
        client.item_public_token_exchange(Plaid::ItemPublicTokenExchangeRequest.new(public_token: public_token))
      end

      item = nil
      ApplicationRecord.transaction do
        item = household.plaid_items.find_or_initialize_by(plaid_item_id: exchange.item_id)
        item.assign_attributes(
          connected_by_user: user,
          institution_id: institution_id,
          institution_name: institution_name || "Connected institution",
          environment: Configuration.environment,
          status: "active",
          consented_at: Time.current,
          consent_policy_version: Configuration::CONSENT_POLICY_VERSION,
          disconnected_at: nil,
          error_code: nil,
          error_message: nil
        )
        item.access_token = exchange.access_token
        item.save!
        audit!(item)
      end

      begin
        TransactionSync.new(item).call
      rescue Error
        # The Item remains connected while Plaid prepares initial history.
        # TransactionSync records a safe status for the participant to retry.
      end
      item.reload
    rescue ActiveRecord::RecordInvalid => e
      raise Error, e.record.errors.full_messages.to_sentence
    end

    private

    attr_reader :household, :user, :public_token, :institution_id, :institution_name

    def audit!(item)
      household.household_audit_events.create!(
        user: user,
        actor_type: "user",
        event_type: "plaid_item.connected",
        auditable_type: "PlaidItem",
        auditable_id: item.id,
        occurred_at: Time.current,
        metadata: { institution_name: item.institution_name, environment: item.environment, consent_policy_version: item.consent_policy_version }
      )
    end
  end
end
