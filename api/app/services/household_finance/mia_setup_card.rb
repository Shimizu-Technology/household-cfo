module HouseholdFinance
  # One setup review card for the whole conversation. It lives in a
  # household_setup draft's metadata, so nothing reaches the plan before Apply.
  # Quotes arrive from the reader; every total here is Ruby arithmetic.
  class MiaSetupCard
    TEXT_FIELDS = %w[household_name primary_goal].freeze
    MONEY_FIELDS = %w[primary_income fixed_expenses flexible_spend].freeze
    DEBT_FIELD = "debt_payment".freeze
    FIELDS = (TEXT_FIELDS + MONEY_FIELDS + [ DEBT_FIELD ]).freeze
    MAX_PARTS = 15
    MAX_NAME = 120
    MAX_GOAL = 500
    TOTAL_LABEL = "Total you gave".freeze
    SAVED_TOTAL_LABEL = "Saved total".freeze
    CARD_LABELS = { "household_name" => "Household name", "primary_goal" => "Main goal", "primary_income" => "Monthly income",
      "fixed_expenses" => "Fixed essentials", "flexible_spend" => "Everyday spending", "debt_payment" => "Debts" }.freeze
    FILLER_WORDS = %w[the my our bill payment payments monthly].freeze
    CADENCE_NOTES = { "weekly" => "a week", "biweekly" => "every two weeks", "yearly" => "a year", "per_paycheck" => "a paycheck" }.freeze

    Update = Data.define(:field, :action, :label, :cents, :note) do
      def initialize(field:, action:, label: nil, cents: nil, note: nil) = super
    end

    attr_reader :fields, :updates, :spending_preferences

    def initialize(household, state: {})
      @household = household
      @fields = state.to_h["fields"].to_h.deep_dup
      @spending_preferences = Array(state.to_h["spending_preferences"]).deep_dup
      @carried = state.to_h["carried"].to_h
      @updates = []
    end

    def to_h = { "version" => 1, "fields" => fields, "spending_preferences" => spending_preferences, "carried" => @carried }

    def empty? = fields.empty?

    # Parts of an earlier applied card still describe a saved total only when
    # they add up to it. Otherwise that breakdown is stale and is not shown.
    def carry_parts_from(previous_state)
      saved = saved_totals
      previous_state.to_h["fields"].to_h.slice(*MONEY_FIELDS).each do |field, value|
        parts = Array(value["parts"]).select { |part| part["counted"] }
        next unless parts.any? && saved[field] && parts.sum { |part| part["cents"].to_i } == saved[field]
        @carried[field] = parts
      end
    end

    def apply_changes(changes)
      apply_text("household_name", changes["household_name"]) if changes["household_name"]
      apply_text("primary_goal", changes["primary_goal"]) if changes["primary_goal"]
      MONEY_FIELDS.each { |field| apply_money(field, changes[field]) if changes[field].present? }
      apply_debts(changes[DEBT_FIELD]) if changes[DEBT_FIELD].present?
      updates
    end

    def apply_preferences(preferences)
      Array(preferences).each do |preference|
        @spending_preferences.reject! { |saved| saved["family"] == preference["family"] }
        @spending_preferences << preference.slice("family", "group", "evidence")
      end
    end

    # A direct edit on the card is the person's own typed value, not a quote.
    def edit_row(field:, action:, part_id: nil, value: nil, label: nil)
      field = field.to_s
      raise ArgumentError, "Unknown setup row" unless field.in?(FIELDS)
      case action.to_s
      when "set" then edit_set(field, part_id, value, label)
      when "remove" then edit_remove(field, part_id)
      else raise ArgumentError, "Unknown setup change"
      end
    end

    def rows
      FIELDS.map do |field|
        field.in?(TEXT_FIELDS) ? text_row(field) : field == DEBT_FIELD ? debt_row : money_row(field)
      end
    end

    # What Apply can save: rows with an unresolved part wait for a monthly amount.
    def setup_updates
      fields.each_with_object({}) do |(field, value), updates|
        next if field == DEBT_FIELD
        if field.in?(TEXT_FIELDS)
          updates[field.to_sym] = value["value"]
        elsif (cents = money_total(field)) && !unresolved?(field)
          updates[field.to_sym] = Money.dollars(cents).to_s
        end
      end
    end

    def debt_state = fields[DEBT_FIELD].to_h

    def debts_changed?
      debt_state["none"] || debt_state["total_cents"] || Array(debt_state["parts"]).any? { |part| !part["saved"] || part["changed"] || part["removed"] }
    end

    def unresolved?(field)
      return false unless field.in?(MONEY_FIELDS)
      Array(fields.dig(field, "parts")).any? { |part| !part["counted"] }
    end

    def unresolved_labels(field)
      Array(fields.dig(field, "parts")).reject { |part| part["counted"] }.map { |part| part["label"] }
    end

    def money_total(field)
      parts = Array(fields.dig(field, "parts")).select { |part| part["counted"] }
      parts.sum { |part| part["cents"].to_i } if parts.any?
    end

    def field_known?(field)
      return debt_known? if field == DEBT_FIELD
      return fields.dig(field, "value").present? if field.in?(TEXT_FIELDS)
      money_total(field).present? && !unresolved?(field)
    end

    def debt_known?
      return true if debt_state["none"] || debt_state["total_cents"]
      parts = Array(debt_state["parts"]).reject { |part| part["removed"] }
      parts.any? && parts.all? { |part| part["minimum_cents"] }
    end

    def debts_without_minimum
      Array(debt_state["parts"]).reject { |part| part["removed"] || part["minimum_cents"] }.map { |part| part["name"] }
    end

    private

    attr_reader :household

    def apply_text(field, value)
      limit = field == "household_name" ? MAX_NAME : MAX_GOAL
      text = value.to_s.squish.truncate(limit, omission: "…")
      return if text.blank? || fields.dig(field, "value") == text
      fields[field] = { "value" => text }
      updates << Update.new(field: field, action: :set, label: text)
    end

    def apply_money(field, change)
      if change["none"]
        replace_with_total(field, 0, kind: "none")
        return updates << Update.new(field: field, action: :none)
      end
      parts = Array(change["parts"])
      total = change["total"]
      fields.delete(field) if change["replace_all"] && (parts.any? || total)
      if total && parts.any?
        parts_cents = counted_sum(parts)
        if total["total_marker"] && parts_cents == total["amount_cents"]
          total = nil
        elsif parts.any? { |part| part["amount_cents"] == total["amount_cents"] } || parts_cents > total["amount_cents"]
          total = nil
          needs = true
        else
          parts = []
        end
      end
      if total
        apply_total(field, total)
      elsif needs
        fields[field] = { "parts" => parts.filter_map { |entry| money_part(entry.merge("label" => entry["label"] || default_label(field)), forced_unclear: true) } }
        updates << Update.new(field: field, action: :needs_monthly, note: "those numbers don't add up")
      else
        parts.each { |part| apply_money_part(field, part) }
      end
      fields.delete(field) if fields.dig(field, "parts") == []
    end

    def counted_sum(parts)
      parts.select { |part| part["cadence"].in?(%w[monthly]) }.sum { |part| part["amount_cents"].to_i }
    end

    def apply_total(field, total)
      if total["cadence"] == "monthly" || (total["cadence"] == "per_paycheck" && total["count"])
        cents = total["amount_cents"] * (total["count"] || 1)
        replace_with_total(field, cents, kind: total["cadence"] == "per_paycheck" ? "paychecks" : "total", note: total["count"] && paycheck_note(total))
        updates << Update.new(field: field, action: :total, cents: cents, note: total["count"] && paycheck_note(total))
      else
        part = money_part(total.merge("label" => default_label(field)))
        fields[field] = { "parts" => [ part ] }
        updates << Update.new(field: field, action: :needs_monthly, label: default_label(field), note: part["note"])
      end
    end

    def paycheck_note(total)
      "#{total['count']} paychecks of #{money(total['amount_cents'])}"
    end

    def replace_with_total(field, cents, kind:, note: nil)
      fields[field] = { "parts" => [ { "id" => new_id, "label" => TOTAL_LABEL, "cents" => cents, "cadence" => "monthly", "counted" => true, "kind" => kind, "note" => note } ] }
    end

    def apply_money_part(field, entry)
      return apply_removal(field, entry["label"]) if entry["op"] == "remove"
      state = fields[field] ||= { "parts" => [] }
      existing = carried_or_saved_parts(field, state)
      unlabeled = entry["label"].blank?
      label = entry["label"].presence || "#{default_label(field)} #{existing.length + 1}"
      match = matching_part(existing, label, exact: entry["op"] == "add") unless unlabeled
      new_part = money_part(entry.merge("label" => label))
      if match
        index = state["parts"].index(match)
        new_part["id"] = match["id"]
        state["parts"][index] = new_part
      elsif entry["op"] == "replace" && saved_totals[field] && existing.none? { |part| part["kind"] != "saved_total" }
        fields.delete(field) if state["parts"].empty?
        return updates << Update.new(field: field, action: :no_breakdown, label: label, cents: saved_totals[field])
      else
        state["parts"] << new_part
      end
      state["parts"] = state["parts"].first(MAX_PARTS)
      action = new_part["counted"] ? (match ? :changed : :added) : :needs_monthly
      updates << Update.new(field: field, action: action, label: label, cents: new_part["counted"] ? new_part["cents"] : nil, note: new_part["note"])
    end

    def apply_removal(field, label)
      state = fields[field] ||= { "parts" => [] }
      existing = carried_or_saved_parts(field, state)
      match = matching_part(existing, label, exact: false)
      unless match
        fields.delete(field) if state["parts"].empty?
        return updates << Update.new(field: field, action: :not_found, label: label)
      end
      state["parts"].delete(match)
      if state["parts"].empty? && saved_totals[field]
        fields[field] = { "parts" => [] }
        return updates << Update.new(field: field, action: :no_breakdown, label: label, cents: saved_totals[field])
      end
      updates << Update.new(field: field, action: :removed, label: match["label"])
    end

    # Saved money enters the card only once a part is added to it, labelled
    # plainly so the addition is visible rather than silently merged.
    def carried_or_saved_parts(field, state)
      if state["parts"].empty?
        carried = Array(@carried[field]).map(&:deep_dup)
        if carried.any?
          state["parts"] = carried
        elsif saved_totals[field]&.positive?
          state["parts"] = [ { "id" => new_id, "label" => SAVED_TOTAL_LABEL, "cents" => saved_totals[field], "cadence" => "monthly", "counted" => true, "kind" => "saved_total" } ]
        end
      end
      state["parts"]
    end

    def money_part(entry, forced_unclear: false)
      cadence = forced_unclear ? "unclear" : entry["cadence"]
      counted = cadence == "monthly"
      cents = entry["amount_cents"]
      { "id" => new_id, "label" => entry["label"].to_s.sub(/\A./, &:upcase), "cents" => counted ? cents : nil, "cadence" => cadence, "counted" => counted, "kind" => "part",
        "stated_cents" => counted ? nil : cents, "note" => counted ? nil : cadence == "unclear" ? "#{money(cents)}, not sure it's monthly" : "#{money(cents)} #{CADENCE_NOTES.fetch(cadence)}" }
    end

    def matching_part(parts, label, exact:)
      words = label_words(label)
      return if words.empty?
      same = parts.select { |part| label_words(part["label"]) == words }
      return same.sole if same.one?
      return if exact
      close = parts.select { |part| (label_words(part["label"]) & words).any? }
      close.sole if close.one?
    end

    def label_words(label)
      (label.to_s.downcase.scan(/[\p{L}]+/) - FILLER_WORDS).map(&:singularize)
    end

    def default_label(field) = { "primary_income" => "Income", "fixed_expenses" => "Bills", "flexible_spend" => "Everyday spending" }.fetch(field)

    def apply_debts(change)
      if change["none"]
        return updates << Update.new(field: DEBT_FIELD, action: :debt_on_file) if debts_with_minimums?
        fields[DEBT_FIELD] = { "none" => true }
        return updates << Update.new(field: DEBT_FIELD, action: :none)
      end
      state = fields[DEBT_FIELD] ||= { "parts" => saved_debt_parts }
      state.delete("none")
      if change["total"]
        state["total_cents"] = change.dig("total", "amount_cents")
        updates << Update.new(field: DEBT_FIELD, action: :total, cents: state["total_cents"])
      end
      Array(change["parts"]).each { |part| apply_debt_part(state, part) }
      fields.delete(DEBT_FIELD) if state["parts"].empty? && state.except("parts").empty?
    end

    def apply_debt_part(state, part)
      match = matching_debt(state["parts"], part["name"])
      if part["op"] == "remove"
        return updates << Update.new(field: DEBT_FIELD, action: :not_found, label: part["name"]) unless match
        match["saved"] ? match["removed"] = true : state["parts"].delete(match)
        return updates << Update.new(field: DEBT_FIELD, action: :removed, label: match["name"])
      end
      state.delete("total_cents")
      if match
        match["minimum_cents"] = part["minimum_cents"] if part["minimum_cents"]
        match["balance_cents"] = part["balance_cents"] if part["balance_cents"]
        match.delete("removed")
        match["changed"] = true if match["saved"]
        updates << debt_update(match, :changed)
      else
        created = { "id" => new_id, "name" => part["name"].to_s.sub(/\A./, &:upcase), "minimum_cents" => part["minimum_cents"], "balance_cents" => part["balance_cents"] }
        state["parts"] << created
        state["parts"] = state["parts"].first(MAX_PARTS)
        updates << debt_update(created, :added)
      end
    end

    def debt_update(part, action)
      Update.new(field: DEBT_FIELD, action: action, label: part["name"], cents: part["minimum_cents"], note: part["minimum_cents"] ? nil : "needs a minimum")
    end

    def matching_debt(parts, name)
      words = label_words(name)
      return if words.empty?
      same = parts.select { |part| label_words(part["name"]) == words }
      return same.sole if same.one?
      close = parts.select { |part| (label_words(part["name"]) & words).any? }
      close.sole if close.one?
    end

    def saved_debt_parts
      DebtPortfolio.new(household).active_debts.map do |debt|
        { "id" => "debt-#{debt.id}", "debt_id" => debt.id, "saved" => true, "name" => debt.label,
          "minimum_cents" => debt.minimum_payment_known? ? debt.minimum_payment_cents : nil,
          "balance_cents" => debt.balance_known? ? debt.balance_cents : nil,
          "saved_minimum_cents" => debt.minimum_payment_known? ? debt.minimum_payment_cents : nil }
      end
    end

    def debts_with_minimums?
      DebtPortfolio.new(household).active_debts.any? { |debt| debt.minimum_payment_known? && debt.minimum_payment_cents.positive? }
    end

    def edit_set(field, part_id, value, label)
      return edit_text(field, value) if field.in?(TEXT_FIELDS)
      cents = Money.cents!(value.to_s.delete(",").strip, message: "Enter an amount like 1500.")
      raise ArgumentError, "Enter an amount of $0 or more." if cents.negative?
      raise ArgumentError, "That amount is too large." if cents > Money::MAX_AMOUNT_CENTS
      return edit_debt(part_id, cents, label) if field == DEBT_FIELD
      state = fields[field] ||= { "parts" => [] }
      part = state["parts"].find { |row| row["id"] == part_id }
      if part
        part.replace(part.merge("cents" => cents, "cadence" => "monthly", "counted" => true, "note" => nil, "stated_cents" => nil, "kind" => part["kind"] == "saved_total" ? "part" : part["kind"]))
      else
        state["parts"] = [ { "id" => new_id, "label" => TOTAL_LABEL, "cents" => cents, "cadence" => "monthly", "counted" => true, "kind" => "total" } ]
      end
    end

    def edit_text(field, value)
      text = value.to_s.squish
      raise ArgumentError, "Enter something first." if text.blank?
      fields[field] = { "value" => text.truncate(field == "household_name" ? MAX_NAME : MAX_GOAL, omission: "…") }
    end

    def edit_debt(part_id, cents, label)
      state = fields[DEBT_FIELD] ||= { "parts" => saved_debt_parts }
      state.delete("none")
      state.delete("total_cents")
      part = state["parts"].find { |row| row["id"] == part_id }
      if part
        part["minimum_cents"] = cents
        part["changed"] = true if part["saved"]
      else
        state["total_cents"] = cents
      end
    end

    def edit_remove(field, part_id)
      state = fields[field]
      return fields.delete(field) if state && field.in?(TEXT_FIELDS)
      return unless state
      if field == DEBT_FIELD
        return fields.delete(field) if part_id.blank?
        part = state["parts"].find { |row| row["id"] == part_id }
        return unless part
        part["saved"] ? part["removed"] = true : state["parts"].delete(part)
        fields.delete(field) if state["parts"].empty?
      else
        part_id.blank? ? fields.delete(field) : state["parts"]&.reject! { |row| row["id"] == part_id }
        fields.delete(field) if fields.dig(field, "parts") == []
      end
    end

    def text_row(field)
      value = fields.dig(field, "value")
      saved = saved_text(field)
      base_row(field, status: value ? "entered" : saved ? "saved" : status_for_missing(field), value_text: value || saved, kind: "text")
    end

    def money_row(field)
      state = fields[field]
      saved_cents = saved_totals[field]
      if state
        rows = Array(state["parts"])
        total = money_total(field)
        status = unresolved?(field) ? "needs_monthly" : "entered"
        note = "#{unresolved_labels(field).to_sentence} #{unresolved_labels(field).one? ? 'needs' : 'need'} a monthly amount." if unresolved?(field)
        # One stated total is the row itself; a sub-row would only repeat it.
        single_total = rows.one? && rows.first["counted"] && rows.first["kind"] != "part"
        note ||= rows.first["note"] if single_total
        return base_row(field, status: status, kind: "money", total_cents: total, parts: single_total ? [] : rows.map { |part| money_row_part(part) }, note: note)
      end
      base_row(field, status: saved_cents ? "saved" : status_for_missing(field), kind: "money", total_cents: saved_cents)
    end

    def money_row_part(part)
      { id: part["id"], label: part["label"], cents: part["cents"], counted: part["counted"], note: part["note"], removable: true }
    end

    def debt_row
      state = fields[DEBT_FIELD]
      unless state
        known = DebtPortfolio.new(household).minimum_payment_known?
        cents = known ? DebtPortfolio.new(household).monthly_minimum_cents : nil
        return base_row(DEBT_FIELD, status: known ? "saved" : status_for_missing(DEBT_FIELD), kind: "debts", total_cents: cents)
      end
      return base_row(DEBT_FIELD, status: "entered", kind: "debts", value_text: "No debts") if state["none"]
      parts = Array(state["parts"]).reject { |part| part["removed"] }.map do |part|
        { id: part["id"], label: part["name"], cents: part["minimum_cents"], counted: part["minimum_cents"].present?,
          note: part["minimum_cents"].nil? ? "needs a minimum" : (part["balance_cents"] ? "#{money(part['balance_cents'])} balance" : nil), removable: true }
      end
      total = state["total_cents"] || (parts.any? && parts.all? { |part| part[:counted] } ? parts.sum { |part| part[:cents] } : nil)
      base_row(DEBT_FIELD, status: debt_known? ? "entered" : "needs_monthly", kind: "debts", total_cents: total, parts: parts,
        note: debts_without_minimum.any? ? "#{debts_without_minimum.to_sentence} #{debts_without_minimum.one? ? 'needs' : 'need'} a monthly minimum." : nil)
    end

    def base_row(field, status:, kind:, value_text: nil, total_cents: nil, parts: [], note: nil)
      { key: field, label: CARD_LABELS.fetch(field), kind: kind, status: status,
        value_text: value_text, total_cents: total_cents, parts: parts, note: note }
    end

    def status_for_missing(field)
      Array(household.setup_skipped_fields).include?(field) ? "skipped" : "missing"
    end

    def saved_text(field)
      return unless confirmed.include?(field)
      field == "household_name" ? household.name.presence : household.primary_goal.presence
    end

    def saved_totals
      @saved_totals ||= begin
        values = DataPresenter.new(household).setup_values
        MONEY_FIELDS.index_with { |field| confirmed.include?(field) ? Money.cents(values.fetch(field.to_sym)) : nil }.compact
      end
    end

    def confirmed = @confirmed ||= SetupStatus.new(household).confirmed_field_keys

    def new_id = SecureRandom.hex(4)

    def money(cents)
      ActiveSupport::NumberHelper.number_to_currency(Money.dollars(cents), precision: cents % 100 == 0 ? 0 : 2)
    end
  end
end
