module Enterprise
  class EventPoll
    def self.call(client: Client.new, max_pages: 10)
      EnterpriseSyncCursor.insert_all([ { name: "workos" } ], unique_by: :index_enterprise_sync_cursors_on_name)
      cursor = EnterpriseSyncCursor.find_by!(name: "workos")
      cursor.with_lock do
        max_pages.times do
          page = client.events(after: cursor.cursor)
          events = page.fetch("data")
          break if events.empty?
          events.each do |data|
            EnterpriseSyncEvent.find_or_create_by!(workos_event_id: data.fetch("id")) do |event|
              event.assign_attributes(event_type: data.fetch("event"), payload: data.fetch("data"), occurred_at: Time.iso8601(data.fetch("created_at")))
            end
          end
          new_cursor = events.last.fetch("id")
          raise Client::Unavailable, "WorkOS events cursor did not advance" if new_cursor == cursor.cursor
          # Inbox and cursor commit together. Processing can resume after a crash.
          cursor.update!(cursor: new_cursor, last_polled_at: Time.current, last_error: nil)
        end
        cursor.update!(last_polled_at: Time.current, last_error: nil)
      end
    rescue StandardError => error
      cursor&.update_columns(last_error: error.class.name, updated_at: Time.current)
      raise
    end
  end
end
