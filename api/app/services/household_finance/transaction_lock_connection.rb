module HouseholdFinance
  # A transaction advisory lock must never join a caller's wider transaction.
  class TransactionLockConnection
    def self.with_connection(pool: ActiveRecord::Base.connection_pool)
      checked_out = pool.checkout
      connection = checked_out
      # Pinned pools can return the caller's connection even from checkout.
      # Preserve its transaction and close the independent adapter afterward.
      begin
        connection = pool.new_connection if checked_out.transaction_open?
        yield connection
      ensure
        connection.disconnect! unless connection.equal?(checked_out)
        pool.checkin(checked_out)
      end
    end
  end
end
