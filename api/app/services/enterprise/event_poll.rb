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
      cursor.with_lock do
        recovered = false
        if expired_checkpoint?(cursor)
          rebaseline!(cursor, client: client)
          recovered = true
        end
        seen_checkpoints = Set.new([ cursor.cursor ])
        max_pages.times do
          begin
            page = read_page(cursor, client: client)
          rescue Client::CursorRejected
            raise if recovered
            rebaseline!(cursor, client: client)
            recovered = true
            seen_checkpoints = Set.new([ cursor.cursor ])
            page = read_page(cursor, client: client)
          end
          events = page.fetch("data")
          break if events.empty?
          events.each do |data|
            EnterpriseSyncEvent.find_or_create_by!(workos_event_id: data.fetch("id")) do |event|
              event.assign_attributes(event_type: data.fetch("event"), payload: data.fetch("data"), occurred_at: Time.iso8601(data.fetch("created_at")))
            end
          end
          new_cursor = events.last.fetch("id")
          raise Client::Unavailable, "WorkOS events cursor did not advance" if seen_checkpoints.include?(new_cursor)
          seen_checkpoints.add(new_cursor)
          # Inbox and cursor commit together. Processing can resume after a crash.
          cursor.update!(cursor: new_cursor, last_polled_at: Time.current, last_error: nil)
        end
        cursor.update!(last_polled_at: Time.current, last_error: nil)
      end
    rescue StandardError => error
      cursor&.update_columns(last_error: error.class.name, updated_at: Time.current)
      raise
    end

    def self.read_page(cursor, client:)
      if cursor.cursor.to_s.start_with?(REPLAY_PREFIX)
        client.events(range_start: cursor.cursor.delete_prefix(REPLAY_PREFIX))
      else
        client.events(after: cursor.cursor)
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

    def self.rebaseline!(cursor, client:)
      # Capture the replay boundary BEFORE reading authoritative state. Changes
      # during reconciliation are replayed afterward, including an empty feed on
      # the first request; the timestamp marker survives a worker restart.
      replay_since = REPLAY_WINDOW.ago.iso8601(6)
      EnterpriseOrganization.order(:id).find_each { |organization| Reconciliation.call(organization, client: client) }
      # Never replace the checkpoint if any organization's complete snapshot fails.
      cursor.update!(cursor: "#{REPLAY_PREFIX}#{replay_since}", last_polled_at: Time.current, last_error: nil)
    end
  end
end
