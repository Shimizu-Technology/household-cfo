require "digest"

module Scorecard
  class AnswerKey
    attr_reader :data, :root

    def initialize(root:, path:)
      @root = Pathname.new(root).realpath
      @data = JSON.parse(Pathname.new(path).read)
      raise ArgumentError, "Unsupported answer key" unless data.fetch("schema_version") == "talun_year_v1"
      @events = data.fetch("events").index_by { |event| event.fetch("event_id") }
    end

    def documents = data.fetch("documents")
    def event(line) = @events.fetch(line.fetch("event_id"))
    def account(key) = data.fetch("accounts").find { |row| row.fetch("account_key") == key } || raise("Unknown answer-key account")

    def expected_months(documents)
      return data.fetch("expected_months") if documents.length == self.documents.length
      paths = documents.map { |doc| doc.fetch("path") }.to_set
      represented = data.fetch("events").select { |event| event.fetch("representations").any? { |copy| paths.include?(copy.fetch("document_path")) && copy["status"] != "pending" } }
      data.fetch("expected_months").to_h do |month, _full_year|
        events = represented.select { |event| event.fetch("date").start_with?(month) }
        categories = data.fetch("categories").to_h { |category| [ category, 0 ] }
        events.each { |event| event.fetch("category_allocations").each { |allocation| categories[allocation.fetch("category")] += allocation.fetch("spending_cents") } }
        [ month, { "spending_by_category_cents" => categories, "total_spending_cents" => categories.values.sum,
          "income_cents" => events.select { |event| event["event_kind"] == "income" }.sum { |event| event.fetch("signed_amount_cents") } } ]
      end
    end

    def source(doc)
      path = root.join(doc.fetch("path")).realpath
      raise ArgumentError, "Source must be inside family directory" unless path.to_s.start_with?(root.to_s + "/")
      raise "Source checksum mismatch" unless Digest::SHA256.file(path).hexdigest == doc.fetch("sha256")
      path
    end

    # Consume a multiset within each source. The coffee twins are indistinguishable
    # to a reader, so either twin may occupy either of the two source rows.
    # No event is invented when extraction omitted it.
    def map_rows(doc, rows)
      remaining = doc.fetch("lines").dup
      group_positions = Hash.new(0)
      rows.to_h do |row|
        cents = row.signed_amount_cents || row.financial_source_evidence&.payload&.fetch("source_amount_text", nil)&.then { |text| HouseholdFinance::Money.document_cents(text, negative_as_magnitude: true) }
        day = (row.posted_on || row.authorized_on)&.iso8601
        candidates = remaining.select { |line| (!day || line["date"] == day) && (!cents || line["signed_amount_cents"].abs == cents.abs) }
        locator = row.locator.to_h
        matched = candidates.find { |line| line.fetch("locator").all? { |key, value| locator[key] == value } }
        matched ||= candidates.first if candidates.one? || candidates.map { |line| event(line)["distinct_purchase_group"] }.compact.uniq.one?
        # A bad amount/date may still be corrected by the participant when the
        # physical source row is unambiguous. Locator alone is insufficient if
        # the model numbered all pages as one continuous list.
        matched ||= remaining.find { |line| line.fetch("locator") == locator }
        remaining.delete(matched) if matched
        if matched && (group = event(matched)["distinct_purchase_group"])
          key = "#{group}:#{matched.fetch('account_key')}"
          group_positions[key] += 1
          matched = matched.merge("match_key" => "#{key}:#{group_positions[key]}")
        end
        [ row.id, matched ]
      end
    end

    def identity_for(doc, source_account, mappings)
      keys = source_account.financial_source_events.filter_map { |row| mappings[row.id]&.fetch("account_key") }.uniq
      keys = doc.fetch("account_keys") if keys.empty? && doc.fetch("account_keys").one?
      raise "Cannot identify extracted account" unless keys.one?
      account(keys.first)
    end
  end
end
