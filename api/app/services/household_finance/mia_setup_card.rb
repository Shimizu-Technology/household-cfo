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
    CADENCE_NOTES = { "weekly" => "a week", "biweekly" => "every two weeks", "yearly" => "a year", "per_paycheck" => "a paycheck", "quarterly" => "a quarter", "twice_yearly" => "twice a year", "twice_monthly" => "twice a month" }.freeze

    NOOP_ACTIONS = %i[not_found no_breakdown debt_on_file card_full combined too_long].freeze
    PAYCHECKS_A_YEAR = { "weekly" => 52, "biweekly" => 26, "quarterly" => 4, "twice_yearly" => 2, "yearly" => 1 }.freeze
    # One figure with no named bills inside it. Changing a bill can only ask
    # for a new total, because nothing says how much of it that bill was.
    LUMP_KINDS = %w[saved_total total paychecks].freeze
    CHANGED_WORDS = /\b(?:went\s+(?:up|down)|gone\s+(?:up|down)|raised|increased|dropped|lowered|changed|more\s+like|now)\b/i
    PLACEHOLDER_DEBT = "Debt payments".freeze

    Update = Data.define(:field, :action, :label, :cents, :note) do
      def initialize(field:, action:, label: nil, cents: nil, note: nil) = super
    end

    attr_reader :fields, :updates, :spending_preferences

    def initialize(household, state: {})
      @household = household
      @fields = state.to_h["fields"].to_h.deep_dup
      @spending_preferences = Array(state.to_h["spending_preferences"]).deep_dup
      @carried = state.to_h["carried"].to_h.deep_dup
      @bases = state.to_h["bases"].to_h.deep_dup
      @revision = state.to_h["revision"].to_i
      @updates = []
    end

    attr_reader :revision

    def to_h = { "version" => 1, "fields" => fields, "spending_preferences" => spending_preferences, "carried" => @carried, "bases" => @bases, "revision" => revision }

    # A row is stale when the saved value moved after she told Mia this one, so
    # a form save is never overwritten by an older number from the card.
    def stale?(field) = @bases.key?(field) && @bases[field] != saved_signature(field)

    def rebase_all = fields.each_key { |field| rebase(field) }

    def unresolved_field_keys
      FIELDS.select { |field| unresolved?(field) || (field == DEBT_FIELD && debts_without_minimum.any? && !only_unknown_minimums_left?) }
    end

    # What must survive a partial Apply: only rows still waiting on an amount.
    def unresolved_state
      kept = fields.slice(*MONEY_FIELDS.select { |field| unresolved?(field) })
      placeholders = Array(debt_state["parts"]).select { |part| part["placeholder"] }
      kept[DEBT_FIELD] = { "parts" => placeholders } if placeholders.any?
      { "fields" => kept.deep_dup, "spending_preferences" => spending_preferences }
    end

    def unresolved_summary
      MONEY_FIELDS.flat_map { |field| unresolved_labels(field) } + Array(debt_state["parts"]).select { |part| part["placeholder"] }.map { |part| part["name"] }
    end

    def empty? = fields.empty?

    # Parts of an earlier applied card still describe a saved total only when
    # they add up to it. Otherwise that breakdown is stale and is not shown.
    def carry_parts_from(previous_state)
      saved = saved_totals
      previous_state.to_h["fields"].to_h.slice(*MONEY_FIELDS).each do |field, value|
        next if @carried[field]
        parts = Array(value["parts"]).select { |part| part["counted"] }
        next unless parts.any? && parts.all? { |part| part["kind"] == "part" } && saved[field] && parts.sum { |part| part["cents"].to_i } == saved[field]
        @carried[field] = parts
      end
    end

    # The bills she can change by name once setup is done.
    def saved_bill_labels
      %w[fixed_expenses flexible_spend].select { |field| saved_totals[field] }.index_with { |field| Array(@carried[field]).map { |part| part["label"] } }
    end

    # A figure that isn't monthly can be worked out, but only she can count it.
    def proposable_part(field)
      Array(fields.dig(field, "parts")).find { |part| !part["counted"] && part["stated_cents"] && PAYCHECKS_A_YEAR.key?(part["cadence"]) }
    end

    def propose_monthly(field)
      part = proposable_part(field)
      return unless part
      times = PAYCHECKS_A_YEAR.fetch(part["cadence"])
      monthly = ((part["stated_cents"] * times / 12.0) / 100).round * 100
      part["proposed_cents"] = monthly
      part["note"] = "#{stated_note(part['stated_cents'], part['cadence'])}, about #{money(monthly)} a month if that's right"
      { stated_cents: part["stated_cents"], cadence: part["cadence"], times: times, monthly_cents: monthly }
    end

    def needs_frequency?(field) = Array(fields.dig(field, "parts")).any? { |part| !part["counted"] && part["needs_frequency"] }

    def proposal_field = MONEY_FIELDS.find { |field| Array(fields.dig(field, "parts")).any? { |part| part["proposed_cents"] } }

    def confirm_proposed_monthly(field)
      part = Array(fields.dig(field, "parts")).find { |row| row["proposed_cents"] }
      return unless part
      part.replace(part.except("proposed_cents").merge("cents" => part["proposed_cents"], "cadence" => "monthly", "counted" => true, "note" => nil, "stated_cents" => nil))
      rebase(field)
      sole = Array(fields.dig(field, "parts")).one?
      updates << Update.new(field: field, action: sole ? :total : :changed, label: part["label"], cents: part["cents"])
    end

    # She said she doesn't have it. The row still says so, but Mia stops asking.
    def mark_minimum_unknown(names)
      Array(debt_state["parts"]).each { |part| part["minimum_unknown"] = true if names.include?(part["name"]) && part["minimum_cents"].nil? }
    end

    def only_unknown_minimums_left?
      pending = Array(debt_state["parts"]).reject { |part| part["removed"] || part["minimum_cents"] }
      pending.any? && pending.all? { |part| part["minimum_unknown"] }
    end

    # A paycheck amount given before she has said how often it comes.
    def set_paycheck_cadence(field, cadence)
      part = Array(fields.dig(field, "parts")).find { |row| !row["counted"] && row["stated_cents"] }
      return unless part && cadence
      part.replace(part.except("needs_frequency").merge("cadence" => cadence, "note" => stated_note(part["stated_cents"], cadence)))
      rebase(field)
    end

    def mark_paycheck_unclear(field)
      part = Array(fields.dig(field, "parts")).find { |row| row["counted"] && row["kind"] == "total" }
      return false unless part
      cents = part["cents"]
      fields[field] = { "parts" => [ money_part({ "label" => default_label(field), "amount_cents" => cents, "cadence" => "unclear" }) ] }
      true
    end

    # Counted paychecks are plain multiplication of what she said, like a
    # stated "2 paychecks of 1400".
    def count_paychecks(field, count)
      part = Array(fields.dig(field, "parts")).find { |row| !row["counted"] && row["stated_cents"] }
      return unless part
      cents = part["stated_cents"] * count
      note = paycheck_note("count" => count, "amount_cents" => part["stated_cents"]) if count > 1
      replace_with_total(field, cents, kind: "paychecks", note: note)
      rebase(field)
      Update.new(field: field, action: :total, cents: cents, note: note).tap { |update| updates << update }
    end

    def apply_changes(changes)
      TEXT_FIELDS.each { |field| rebasing(field) { apply_text(field, changes[field]) } if changes[field] }
      MONEY_FIELDS.each { |field| rebasing(field) { apply_money(field, changes[field]) } if changes[field].present? }
      rebasing(DEBT_FIELD) { apply_debts(changes[DEBT_FIELD]) } if changes[DEBT_FIELD].present?
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
      rebase(field)
    end

    def rows
      FIELDS.map do |field|
        row = field.in?(TEXT_FIELDS) ? text_row(field) : field == DEBT_FIELD ? debt_row : money_row(field)
        stale?(field) ? row.merge(note: "Your saved number changed after you told me this. Tap to enter it again.") : row
      end
    end

    # What Apply can save: rows with an unresolved part wait for a monthly amount.
    def setup_updates
      fields.each_with_object({}) do |(field, value), updates|
        next if field == DEBT_FIELD || stale?(field)
        if field.in?(TEXT_FIELDS)
          updates[field.to_sym] = value["value"]
        elsif (cents = money_total(field))
          updates[field.to_sym] = Money.dollars(cents).to_s
        end
      end
    end

    def debt_state = fields[DEBT_FIELD].to_h

    def debts_changed?
      return false if stale?(DEBT_FIELD)
      debt_state["none"] || debt_state["total_cents"] || Array(debt_state["parts"]).any? { |part| !part["placeholder"] && (!part["saved"] || part["changed"] || part["removed"]) }
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
      limit = text_limit(field)
      text = value.to_s.squish
      return updates << Update.new(field: field, action: :too_long, cents: limit) if text.length > limit
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
      seeded = state["parts"].empty?
      existing = carried_or_saved_parts(field, state)
      unlabeled = entry["label"].blank?
      label = entry["label"].presence || "#{default_label(field)} #{existing.length + 1}"
      match = matching_part(existing, label, exact: entry["op"] == "add") unless unlabeled
      new_part = money_part(entry.merge("label" => label))
      combined = match if match && combined_row?(match, label)
      combined ||= existing.find { |part| combined_row?(part, label) && (label_words(label) - label_words(part["label"])).empty? } unless match || unlabeled
      return updates << Update.new(field: field, action: :combined, label: label, note: combined["label"]) if combined
      if !match && state["parts"].length >= MAX_PARTS
        return updates << Update.new(field: field, action: :card_full, label: label)
      end
      if match
        index = state["parts"].index(match)
        new_part["id"] = match["id"]
        state["parts"][index] = new_part
      elsif lump_only?(existing) && !unlabeled && (entry["op"] == "replace" || entry["source"].to_s.match?(CHANGED_WORDS))
        fields.delete(field) if seeded
        return updates << Update.new(field: field, action: :no_breakdown, label: label, cents: existing.sum { |part| part["cents"].to_i })
      else
        state["parts"] << new_part
      end
      action = new_part["counted"] ? (match ? :changed : :added) : :needs_monthly
      updates << Update.new(field: field, action: action, label: label, cents: new_part["counted"] ? new_part["cents"] : nil, note: new_part["note"])
    end

    def apply_removal(field, label)
      state = fields[field] ||= { "parts" => [] }
      seeded = state["parts"].empty?
      existing = carried_or_saved_parts(field, state)
      match = matching_part(existing, label, exact: false)
      unless match
        if lump_only?(existing)
          fields.delete(field) if seeded
          return updates << Update.new(field: field, action: :no_breakdown, label: label, cents: existing.sum { |part| part["cents"].to_i })
        end
        fields.delete(field) if state["parts"].empty?
        return updates << Update.new(field: field, action: :not_found, label: label)
      end
      return updates << Update.new(field: field, action: :combined, label: label, note: match["label"]) if combined_row?(match, label)
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

    def lump_only?(parts) = parts.any? && parts.all? { |part| LUMP_KINDS.include?(part["kind"]) }

    def money_part(entry, forced_unclear: false)
      cadence = forced_unclear ? "unclear" : entry["cadence"]
      counted = cadence == "monthly"
      cents = entry["amount_cents"]
      extra = entry["needs_frequency"] && !counted ? { "needs_frequency" => true } : {}
      extra.merge({ "id" => new_id, "label" => entry["label"].to_s.sub(/\A./, &:upcase), "cents" => counted ? cents : nil, "cadence" => cadence, "counted" => counted, "kind" => "part",
        "stated_cents" => counted ? nil : cents, "note" => counted ? nil : stated_note(cents, cadence) })
    end

    def stated_note(cents, cadence)
      cadence == "unclear" ? "#{money(cents)}, not sure it's monthly" : "#{money(cents)} #{CADENCE_NOTES.fetch(cadence)}"
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

    def combined_row?(part, label)
      part["label"].to_s.match?(/\s(?:and|n|&|\+)\s|\//i) && label_words(part["label"]) != label_words(label)
    end

    def label_words(label)
      (label.to_s.downcase.scan(/[\p{L}]+/) - FILLER_WORDS).map(&:singularize)
    end

    def default_label(field) = { "primary_income" => "Income", "fixed_expenses" => "Bills", "flexible_spend" => "Everyday spending" }.fetch(field)

    def apply_debts(change)
      if change["none"]
        return updates << Update.new(field: DEBT_FIELD, action: :debt_on_file) if DebtPortfolio.new(household).active_debts.any?
        fields[DEBT_FIELD] = { "none" => true }
        return updates << Update.new(field: DEBT_FIELD, action: :none)
      end
      state = fields[DEBT_FIELD] ||= {}
      state.delete("none")
      state["parts"] ||= saved_debt_parts
      apply_debt_total(state, change["total"]) if change["total"]
      Array(change["parts"]).each { |part| apply_debt_part(state, part) }
      fields.delete(DEBT_FIELD) if state["parts"].empty? && state.except("parts").empty?
    end

    # A figure that isn't monthly waits on its own row until she gives one.
    def apply_debt_total(state, total)
      state["parts"].reject! { |part| part["placeholder"] }
      if total["cadence"] == "monthly"
        state["total_cents"] = total["amount_cents"]
        updates << Update.new(field: DEBT_FIELD, action: :total, cents: state["total_cents"])
      else
        state.delete("total_cents")
        placeholder = { "id" => new_id, "name" => PLACEHOLDER_DEBT, "placeholder" => true, "minimum_cents" => nil, "balance_cents" => nil, "minimum_note" => stated_note(total["amount_cents"], total["cadence"]) }
        state["parts"] << placeholder
        updates << Update.new(field: DEBT_FIELD, action: :needs_monthly, label: PLACEHOLDER_DEBT, note: placeholder["minimum_note"])
      end
    end

    def apply_debt_part(state, part)
      match = matching_debt(state["parts"], part["name"])
      if part["op"] == "remove"
        return updates << Update.new(field: DEBT_FIELD, action: :not_found, label: part["name"]) unless match
        match["saved"] ? match["removed"] = true : state["parts"].delete(match)
        return updates << Update.new(field: DEBT_FIELD, action: :removed, label: match["name"])
      end
      if !match && state["parts"].count { |row| !row["placeholder"] } >= MAX_PARTS
        return updates << Update.new(field: DEBT_FIELD, action: :card_full, label: part["name"])
      end
      state.delete("total_cents")
      state["parts"].reject! { |row| row["placeholder"] }
      if match
        apply_debt_amounts(match, part)
        match.delete("removed")
        match["changed"] = true if match["saved"]
        updates << debt_update(match, :changed)
      else
        created = { "id" => new_id, "name" => part["name"].to_s.sub(/\A./, &:upcase), "minimum_cents" => nil, "balance_cents" => part["balance_cents"] }
        apply_debt_amounts(created, part)
        state["parts"] << created
        updates << debt_update(created, :added)
      end
    end

    def apply_debt_amounts(row, part)
      row["balance_cents"] = part["balance_cents"] if part["balance_cents"]
      if part["minimum_cents"]
        row["minimum_cents"] = part["minimum_cents"]
        row.delete("minimum_note")
      elsif part["stated_cents"] && row["minimum_cents"].nil?
        row["minimum_note"] = stated_note(part["stated_cents"], part["cadence"])
      end
    end

    def debt_update(part, action)
      note = part["minimum_note"] ? "needs a monthly minimum (#{part['minimum_note']})" : "needs a minimum" unless part["minimum_cents"]
      Update.new(field: DEBT_FIELD, action: action, label: part["name"], cents: part["minimum_cents"], note: note)
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

    def edit_set(field, part_id, value, _label)
      return edit_text(field, value) if field.in?(TEXT_FIELDS)
      cents = edited_cents(value)
      return edit_debt(part_id, cents) if field == DEBT_FIELD
      state = fields[field] ||= { "parts" => [] }
      if part_id.present?
        part = state["parts"].find { |row| row["id"] == part_id }
        raise ArgumentError, "That row changed. Look at your card again." unless part
        part.replace(part.except("proposed_cents", "needs_frequency").merge("cents" => cents, "cadence" => "monthly", "counted" => true, "note" => nil, "stated_cents" => nil, "kind" => part["kind"] == "saved_total" ? "part" : part["kind"]))
      else
        state["parts"] = [ { "id" => new_id, "label" => TOTAL_LABEL, "cents" => cents, "cadence" => "monthly", "counted" => true, "kind" => "total" } ]
      end
    end

    def edited_cents(value)
      text = value.to_s.strip
      raise ArgumentError, "Enter an amount like 1500." if text.match?(ParticipantMessageReader::MISPLACED_COMMA)
      cents = Money.cents!(text.delete(","), message: "Enter an amount like 1500.")
      raise ArgumentError, "Enter an amount of $0 or more." if cents.negative?
      raise ArgumentError, "That amount is too large." if cents > Money::MAX_AMOUNT_CENTS
      cents
    end

    def text_limit(field) = field == "household_name" ? MAX_NAME : MAX_GOAL

    def edit_text(field, value)
      text = value.to_s.squish
      raise ArgumentError, "Enter something first." if text.blank?
      raise ArgumentError, "Keep this to #{text_limit(field)} characters or fewer." if text.length > text_limit(field)
      fields[field] = { "value" => text }
    end

    def edit_debt(part_id, cents)
      state = fields[DEBT_FIELD] ||= {}
      state.delete("none")
      state["parts"] ||= saved_debt_parts
      if part_id.present?
        part = state["parts"].find { |row| row["id"] == part_id }
        raise ArgumentError, "That row changed. Look at your card again." unless part
        if part["placeholder"]
          state["parts"].delete(part)
          state["total_cents"] = cents
          return
        end
        state.delete("total_cents")
        part["minimum_cents"] = cents
        part.delete("minimum_note")
        part["changed"] = true if part["saved"]
      else
        raise ArgumentError, "Change each debt on its own row." if state["parts"].any? { |row| !row["placeholder"] && !row["removed"] }
        state["parts"].reject! { |row| row["placeholder"] }
        state["total_cents"] = cents
      end
    end

    def edit_remove(field, part_id)
      state = fields[field]
      return fields.delete(field) if state && field.in?(TEXT_FIELDS)
      return unless state
      if field == DEBT_FIELD
        return fields.delete(field) if part_id.blank?
        part = Array(state["parts"]).find { |row| row["id"] == part_id }
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
          note: part["minimum_cents"].nil? ? (part["minimum_note"] || "needs a minimum") : (part["balance_cents"] ? "#{money(part['balance_cents'])} balance" : nil), removable: true }
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

    def rebasing(field)
      already = updates.length
      yield
      rebase(field) if updates.drop(already).any? { |update| !update.action.in?(NOOP_ACTIONS) }
    end

    def rebase(field) = @bases[field] = saved_signature(field)

    def saved_signature(field)
      return confirmed.include?(field) ? saved_text(field) : nil if field.in?(TEXT_FIELDS)
      return saved_totals[field] if field.in?(MONEY_FIELDS)
      portfolio = DebtPortfolio.new(household)
      [ portfolio.minimum_payment_known?, portfolio.monthly_minimum_cents, portfolio.active_debts.length ]
    end

    def new_id = SecureRandom.hex(4)

    def money(cents)
      ActiveSupport::NumberHelper.number_to_currency(Money.dollars(cents), precision: cents % 100 == 0 ? 0 : 2)
    end
  end
end
