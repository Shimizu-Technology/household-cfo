require "set"

module Enterprise
  class EventPoll
    REPLAY_PREFIX = "replay_since:".freeze
    CURSOR_RETENTION = 89.days
    REPLAY_WINDOW = 5.minutes
    MAX_RANGE_AGE = 29.days

    def self.call(client: Client.new, max_pages: 10)
      EnterpriseSyncCursor.insert_all([ { name: "workos" } ], unique_by: :index_enterprise_sync_cursors_on_name)
      cursor = EnterpriseSyncCursor.find_by!(name: "workos")
      # A session advisory lock excludes other pollers without holding a SQL
      # transaction or cursor row lock across provider requests.
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        locked = connection.select_value("SELECT pg_try_advisory_lock(721164203985142)")
        return unless locked
        begin
          cursor.reload
          checkpoint = cursor.cursor
          recovered = false
          if expired_checkpoint?(cursor)
            checkpoint = rebaseline!(cursor, client: client)
            recovered = true
          end
          seen_checkpoints = Set.new([ checkpoint ])
          inbox = []
          max_pages.times do
            begin
              page = read_page(checkpoint, client: client)
            rescue Client::CursorRejected
              raise if recovered
              checkpoint = rebaseline!(cursor, client: client)
              recovered = true
              seen_checkpoints = Set.new([ checkpoint ])
              inbox.clear
              page = read_page(checkpoint, client: client)
            end
            events = page.fetch("data")
            break if events.empty?
            new_cursor = events.last.fetch("id")
            raise Client::Unavailable, "WorkOS events cursor did not advance" if seen_checkpoints.include?(new_cursor)
            seen_checkpoints.add(new_cursor)
            inbox.concat(events)
            checkpoint = new_cursor
          end
          # Validate the bounded feed before writing anything. Inbox and cursor
          # commit together; an outage or cycle can never skip pending events.
          cursor.with_lock do
            inbox.each do |data|
              EnterpriseSyncEvent.find_or_create_by!(workos_event_id: data.fetch("id")) do |event|
                event.assign_attributes(event_type: data.fetch("event"), payload: data.fetch("data"), occurred_at: Time.iso8601(data.fetch("created_at")))
              end
            end
            cursor.update!(cursor: checkpoint, last_polled_at: Time.current, last_error: nil)
          end
        rescue StandardError => error
          cursor.update_columns(last_error: error.class.name, updated_at: Time.current)
          raise
        ensure
          connection.execute("SELECT pg_advisory_unlock(721164203985142)")
        end
      end
    end

    def self.read_page(checkpoint, client:)
      if checkpoint.to_s.start_with?(REPLAY_PREFIX)
        client.events(range_start: checkpoint.delete_prefix(REPLAY_PREFIX))
      else
        client.events(after: checkpoint)
      end
    end

    def self.expired_checkpoint?(cursor)
      return false if cursor.cursor.blank?
      if cursor.cursor.start_with?(REPLAY_PREFIX)
        return Time.iso8601(cursor.cursor.delete_prefix(REPLAY_PREFIX)) < MAX_RANGE_AGE.ago
      end
      occurred_at = EnterpriseSyncEvent.find_by(workos_event_id: cursor.cursor)&.occurred_at
      (occurred_at && occurred_at < CURSOR_RETENTION.ago) || (cursor.last_polled_at && cursor.last_polled_at < CURSOR_RETENTION.ago)
    rescue ArgumentError
      true
    end

    def self.rebaseline!(_cursor, client:)
      # Capture the replay boundary BEFORE reading authoritative state. Changes
      # during reconciliation are replayed afterward, including an empty feed on
      # the first request; the timestamp marker survives a worker restart.
      replay_since = REPLAY_WINDOW.ago.iso8601(6)
      first_error = nil
      EnterpriseOrganization.order(:id).find_each do |organization|
        begin
          Reconciliation.call(organization, client: client)
        rescue StandardError => error
          first_error ||= error
        end
      end
      # Keep successful security updates even when another tenant fails, but
      # never replace the checkpoint until every snapshot and replay succeeds.
      raise first_error if first_error
      "#{REPLAY_PREFIX}#{replay_since}"
    end
  end
end
