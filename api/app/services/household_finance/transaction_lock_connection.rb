module HouseholdFinance
  # A transaction advisory lock must never join a caller's wider transaction.
  class TransactionLockConnection
    INDEPENDENT_POOLS = Concurrent::Map.new

    def self.with_connection(pool: ActiveRecord::Base.connection_pool)
      checked_out = pool.checkout
      begin
        # Pinned pools can return the caller's connection even from checkout.
        # A separate bounded pool preserves that transaction and reuses its
        # adapters instead of paying for a new backend on every admission.
        if checked_out.transaction_open?
          independent_pool(pool).with_connection { |connection| yield connection }
        else
          yield checked_out
        end
      ensure
        pool.checkin(checked_out)
      end
    end

    def self.independent_pool(pool)
      config = INDEPENDENT_POOLS.compute_if_absent(pool) do
        source_config = pool.pool_config
        # PoolConfig registers the pool with Rails' fork lifecycle too.
        ActiveRecord::ConnectionAdapters::PoolConfig.new(
          source_config.connection_descriptor, source_config.db_config, source_config.role, source_config.shard
        )
      end
      config.pool
    end
    private_class_method :independent_pool
  end
end
