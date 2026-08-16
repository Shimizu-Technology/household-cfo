module PlaidIntegration
  class ItemHealth
    STALE_AFTER = 36.hours
    INITIAL_SYNC_GRACE_PERIOD = 1.hour

    def initialize(item, now: Time.current)
      @item = item
      @now = now
    end

    def as_json
      {
        state: state,
        label: label,
        message: message,
        requires_attention: requires_attention?,
        last_successful_update_at: item.last_successful_update_at,
        stale_after: stale_after
      }
    end

    def state
      return "disconnected" if item.status == "disconnected"
      return "disconnecting" if item.status == "disconnecting"
      return "action_required" if item.status == "update_required"
      return "error" if item.status == "error"
      return "initializing" if item.last_successful_update_at.blank? && item.created_at > now - INITIAL_SYNC_GRACE_PERIOD
      return "stale" if item.last_successful_update_at.blank? || item.last_successful_update_at < stale_after

      "healthy"
    end

    def requires_attention?
      state.in?(%w[action_required error stale])
    end

    private

    attr_reader :item, :now

    def stale_after
      now - STALE_AFTER
    end

    def label
      {
        "healthy" => "Feed current",
        "initializing" => "Preparing history",
        "stale" => "Feed delayed",
        "action_required" => "Reconnect needed",
        "error" => "Sync needs attention",
        "disconnecting" => "Disconnect pending",
        "disconnected" => "Disconnected"
      }.fetch(state)
    end

    def message
      {
        "healthy" => "Plaid has updated this connection within the expected window.",
        "initializing" => "The first transaction history sync is still being prepared.",
        "stale" => "No successful update has completed in more than 36 hours. A recovery sync is queued daily.",
        "action_required" => "The bank needs the household to reconnect before updates can continue.",
        "error" => "The latest sync failed. Try again, then contact support if the problem continues.",
        "disconnecting" => "Plaid removal has not completed. Retry the disconnect to finish safely.",
        "disconnected" => "Plaid access and unapproved source data have been removed."
      }.fetch(state)
    end
  end
end
