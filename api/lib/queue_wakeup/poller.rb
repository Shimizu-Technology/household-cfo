# Experimental Solid Queue 1.4 adapter. Notifications are hints; the durable
# tables and Solid Queue's claims, leases, retries and heartbeats remain authoritative.
module QueueWakeup
  CHANNEL = "vera_queue_ready"
  RECOVERY_SECONDS = 60

  module Poller
    private
      def poll
        connect_listener unless @queue_listener
        delay = super
        return delay unless @queue_listener
        if is_a?(SolidQueue::Dispatcher)
          due = SolidQueue::ScheduledExecution.minimum(:scheduled_at)
          due ? [ [ due - Time.current, 0 ].max, RECOVERY_SECONDS ].min : RECOVERY_SECONDS
        else
          RECOVERY_SECONDS
        end
      end

      def connect_listener
        # An explicitly supplied session connection, never an AR checkout or
        # transaction-pooled connection. Created inside the worker after fork.
        @queue_listener = PG.connect(ENV.fetch("QUEUE_LISTEN_DATABASE_URL"), connect_timeout: 2)
        @queue_listener.exec("LISTEN #{CHANNEL}")
      rescue PG::Error, IOError, SystemCallError => error
        close_listener
        SolidQueue.logger.warn("Queue listener unavailable: #{error.class}; using standard polling")
      end

      def interruptible_sleep(delay)
        return super unless @queue_listener && delay.positive?
        readable = IO.select([ self_pipe[:reader], @queue_listener.socket_io ], nil, nil, delay)&.first || []
        if readable.include?(@queue_listener.socket_io)
          @queue_listener.consume_input
          nil while @queue_listener.notifies
        end
        super(0.000001) if readable.include?(self_pipe[:reader])
      rescue PG::Error, IOError, SystemCallError
        close_listener
        # Next iteration reconnects and claims durable work before sleeping.
      end

      def shutdown
        super
      ensure
        close_listener
      end

      def close_listener
        @queue_listener&.finish unless @queue_listener&.finished?
        @queue_listener = nil
      end
  end
end
