module HouseholdFinance
  # The one change card for household details, before setup is finished and
  # after. It lives in a household_setup draft's metadata, so nothing reaches
  # the plan before Apply. Quotes arrive from the reader; every total here is
  # Ruby arithmetic. Which fields exist, and how each is held, comes from
  # HouseholdFieldRegistry.
  class MiaSetupCard
    REGISTRY = HouseholdFieldRegistry
    TEXT_FIELDS = REGISTRY::TEXT_KEYS
    MONEY_FIELDS = REGISTRY::MONEY_KEYS
    BILL_FIELDS = REGISTRY::BILL_KEYS
    BALANCE_FIELDS = REGISTRY::BALANCE_KEYS
    MONTHS_FIELDS = REGISTRY::MONTHS_KEYS
    DEBT_FIELD = REGISTRY::DEBT_KEY
    FIELDS = REGISTRY::KEYS
    MAX_PARTS = 15
    MAX_NAME = REGISTRY::MAX_TEXT.fetch("household_name")
    MAX_GOAL = REGISTRY::MAX_TEXT.fetch("primary_goal")
    TOTAL_LABEL = "Total you gave".freeze
    SAVED_TOTAL_LABEL = "Saved total".freeze
    CARD_LABELS = REGISTRY::FIELDS.to_h { |field| [ field.key, field.label ] }.freeze
    FILLER_WORDS = %w[the my our bill payment payments monthly].freeze
    CADENCE_NOTES = { "weekly" => "a week", "biweekly" => "every two weeks", "yearly" => "a year", "per_paycheck" => "a paycheck", "quarterly" => "a quarter", "twice_yearly" => "twice a year", "twice_monthly" => "twice a month" }.freeze
    # Labels the starting-picture form and older chat setups used for one whole
    # layer. A saved row with one of these names is a total, not a named bill.
    AGGREGATE_LABELS = [ "Fixed essentials", "Flexible spending", "Everyday spending", "Expected sinking fund", "Unexpected sinking fund", "Planned yearly costs", "Surprise fund" ].map(&:downcase).freeze

    NOOP_ACTIONS = %i[not_found no_breakdown debt_on_file card_full combined too_long kept_edit].freeze
    # How many times a year a stated amount comes. Mia offers the monthly
    # figure and only counts it once she says yes.
    TIMES_A_YEAR = { "weekly" => 52, "biweekly" => 26, "twice_monthly" => 24, "quarterly" => 4, "twice_yearly" => 2, "yearly" => 1 }.freeze
    PAYCHECKS_A_YEAR = TIMES_A_YEAR
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
      @bases = state.to_h["bases"].to_h.deep_dup
      @revision = state.to_h["revision"].to_i
      @change_mode = state.to_h["change_mode"]
      @updates = []
    end

    attr_reader :revision

    def to_h = { "version" => 2, "fields" => fields, "spending_preferences" => spending_preferences, "bases" => @bases, "revision" => revision, "change_mode" => @change_mode }.compact

    # A row is stale when the saved value moved after she told Mia this one, so
    # a form save is never overwritten by an older number from the card.
    def stale?(field) = @bases.key?(field) && @bases[field] != saved_signature(field)

    def rebase_all = fields.each_key { |field| rebase(field) }

    def unresolved_field_keys
      FIELDS.select { |field| (unresolved?(field) && !parked?(field)) || (field == DEBT_FIELD && debts_without_minimum.any? && !only_unknown_minimums_left?) }
    end

    # What must survive a partial Apply: only rows still waiting on an amount.
    def unresolved_state
      kept = fields.slice(*MONEY_FIELDS.select { |field| unresolved?(field) }).deep_dup
      # Counted bills were just saved, so the next card knows them by name.
      kept.slice(*BILL_FIELDS).each_value do |state|
        state["parts"] = Array(state["parts"]).reject { |part| part["removed"] }.map do |part|
          part["counted"] && itemized_part?(part) ? part.merge("saved_label" => part["saved_label"] || part["label"], "saved_cents" => part["cents"]) : part
        end
      end
      placeholders = Array(debt_state["parts"]).select { |part| part["placeholder"] }
      kept[DEBT_FIELD] = { "parts" => placeholders } if placeholders.any?
      { "fields" => kept.deep_dup, "spending_preferences" => spending_preferences }
    end

    def unresolved_summary
      MONEY_FIELDS.flat_map { |field| unresolved_labels(field) } + Array(debt_state["parts"]).select { |part| part["placeholder"] }.map { |part| part["name"] }
    end

    def empty? = fields.empty?

    # Saved bills by name, so the reader can quote the one she means.
    def saved_bill_lines
      BILL_FIELDS.each_with_object({}) do |field, lines|
        parts = saved_bill_parts(field)
        lines[field] = parts.map { |part| "#{part['label']} #{money(part['cents'])}" } if parts.any?
      end
    end

    # The figure Mia is waiting on her to accept, if any.
    def offer(field)
      Array(fields.dig(field, "parts")).find { |part| !part["counted"] && !part["removed"] && part["proposed_cents"] }
    end

    def proposal_field = MONEY_FIELDS.find { |field| offer(field) }

    def proposable_part(field)
      Array(fields.dig(field, "parts")).find { |part| !part["counted"] && !part["removed"] && (part["range"] || (part["stated_cents"] && TIMES_A_YEAR.key?(part["cadence"]))) }
    end

    # Works out the figure to offer: a pay rhythm becomes a month, two numbers
    # meet in the middle. Ruby does the arithmetic; she decides.
    def propose_monthly(field)
      part = proposable_part(field)
      return unless part
      proposal = if part["range"]
        low, high = part["range"]
        { kind: :range, low_cents: low, high_cents: high, monthly_cents: (((low + high) / 2.0) / 100).round * 100 }
      else
        times = TIMES_A_YEAR.fetch(part["cadence"])
        exact = part["stated_cents"] * times / 12.0
        { kind: :times, stated_cents: part["stated_cents"], cadence: part["cadence"], times: times, monthly_cents: (exact / 100).round * 100, exact: (exact % 100).zero? && ((exact / 100).round * 100) == exact }
      end
      part["proposed_cents"] = proposal[:monthly_cents]
      part["note"] = proposal_note(part, proposal)
      part["offer_question"] = offer_question(part, proposal)
      proposal
    end

    def offer_question_for(field) = offer(field)&.fetch("offer_question", nil)

    def offered?(field) = offer(field)&.fetch("offered", false) == true

    def mark_offered(field)
      offer(field)&.store("offered", true)
    end

    # She was asked once and didn't say. The row keeps waiting, and Mia moves on.
    def park(field)
      Array(fields.dig(field, "parts")).each { |part| part["parked"] = true unless part["counted"] }
    end

    def parked?(field) = unresolved?(field) && Array(fields.dig(field, "parts")).reject { |part| part["counted"] || part["removed"] }.all? { |part| part["parked"] }

    def needs_frequency?(field) = Array(fields.dig(field, "parts")).any? { |part| !part["counted"] && part["needs_frequency"] }

    def confirm_proposed_monthly(field)
      part = offer(field)
      return unless part
      part.replace(part.except("proposed_cents", "range", "offered", "parked", "offer_question").merge("cents" => part["proposed_cents"], "cadence" => "monthly", "counted" => true, "note" => nil, "stated_cents" => nil))
      rebase(field)
      sole = Array(fields.dig(field, "parts")).reject { |row| row["removed"] }.one?
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

    # message is her whole message: a field she just set by hand on the card
    # only changes again when she names it.
    def apply_changes(changes, message: nil)
      @message = message.to_s
      TEXT_FIELDS.each { |field| rebasing(field) { apply_text(field, changes[field]) } if changes[field] }
      MONEY_FIELDS.each { |field| rebasing(field) { guarded(field, changes[field]) { apply_money(field, changes[field]) } } if changes[field].present? }
      BALANCE_FIELDS.each { |field| rebasing(field) { guarded(field, changes[field]) { apply_balance(field, changes[field]) } } if changes[field].present? }
      MONTHS_FIELDS.each { |field| rebasing(field) { apply_months(field, changes[field]) } if changes[field].present? }
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
      fields[field]["edited"] = true if fields[field] && action.to_s == "set"
      rebase(field)
    end

    def edited?(field) = fields.dig(field, "edited") == true

    # Only the rows she is changing. Saved rows she hasn't touched stay off
    # the card, so it stays short on a phone.
    def rows
      FIELDS.filter_map do |field|
        next unless fields.key?(field)
        row = row_for(field)
        stale?(field) ? row.merge(note: "Your saved number changed after you told me this. Tap to enter it again.") : row
      end
    end

    # Required fields not on the card yet, while setup is still being finished.
    def still_to_add
      missing = SetupStatus.new(household).missing_field_keys
      skipped = Array(household.setup_skipped_fields)
      open = missing.reject { |field| fields.key?(field) && field_known?(field) }
      { still_to_add: (open - skipped).map { |field| CARD_LABELS.fetch(field) }, skipped: (open & skipped).map { |field| CARD_LABELS.fetch(field) } }
    end

    # What Apply can save as a whole value: rows with an unresolved part wait
    # for a monthly amount, and named bills go through bill_changes instead.
    def setup_updates
      fields.each_with_object({}) do |(field, value), updates|
        next if field == DEBT_FIELD || field == "credit_card_debt" || stale?(field) || itemized?(field)
        if field.in?(TEXT_FIELDS)
          updates[field.to_sym] = value["value"]
        elsif field.in?(BALANCE_FIELDS)
          updates[field.to_sym] = Money.dollars(value["cents"]).to_s if value["cents"]
        elsif field.in?(MONTHS_FIELDS)
          updates[field.to_sym] = value["value"]
        elsif (cents = money_total(field))
          updates[field.to_sym] = Money.dollars(cents).to_s
        end
      end
    end

    # A bills row saved bill by bill: the whole list she wants, with each saved
    # row's own name so Apply can find its budget row.
    def bill_changes
      BILL_FIELDS.each_with_object({}) do |field, changes|
        next unless itemized?(field) && !stale?(field)
        parts = Array(fields.dig(field, "parts")).select { |part| part["counted"] || part["removed"] }
        next if parts.empty?
        changes[field] = {
          "keep" => parts.reject { |part| part["removed"] }.map { |part| { "label" => part["label"], "cents" => part["cents"], "saved_label" => part["saved_label"], "saved_cents" => part["saved_cents"] }.compact },
          "remove" => parts.select { |part| part["removed"] && part["saved_label"] }.map { |part| part["saved_label"] }
        }
      end
    end

    # A bills row is saved bill by bill once it names a bill, or once it
    # changes a saved breakdown.
    def itemized?(field)
      return false unless field.in?(BILL_FIELDS)
      Array(fields.dig(field, "parts")).any? { |part| itemized_part?(part) } || saved_bill_parts(field).length > 1
    end

    def itemized_part?(part) = part["kind"].in?(%w[part remainder]) || part["saved_label"].present?

    def debt_state = fields[DEBT_FIELD].to_h

    def debts_changed?
      return false if stale?(DEBT_FIELD)
      debt_state["none"] || debt_state["total_cents"] || Array(debt_state["parts"]).any? { |part| !part["placeholder"] && (!part["saved"] || part["changed"] || part["removed"]) }
    end

    def debt_balance_cents = fields.dig("credit_card_debt", "cents")

    def unresolved?(field)
      return false unless field.in?(MONEY_FIELDS)
      Array(fields.dig(field, "parts")).any? { |part| !part["counted"] && !part["removed"] }
    end

    def unresolved_labels(field)
      Array(fields.dig(field, "parts")).reject { |part| part["counted"] || part["removed"] }.map { |part| part["label"] }
    end

    def money_total(field)
      parts = Array(fields.dig(field, "parts")).select { |part| part["counted"] && !part["removed"] }
      parts.sum { |part| part["cents"].to_i } if parts.any? || Array(fields.dig(field, "parts")).any? { |part| part["removed"] }
    end

    def field_known?(field)
      return debt_known? if field == DEBT_FIELD
      return fields.dig(field, "value").present? if field.in?(TEXT_FIELDS) || field.in?(MONTHS_FIELDS)
      return fields.dig(field, "cents").present? if field.in?(BALANCE_FIELDS)
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

    # She set this row herself on the card. An unlabelled number in a later
    # message that doesn't name the field is not allowed to replace it.
    def guarded(field, change)
      return yield unless edited?(field) && !REGISTRY.mentioned?(field, @message)
      labelled = Array(change["parts"]).any? { |part| part["label"].present? && part["op"] != "remove" }
      return yield if labelled
      updates << Update.new(field: field, action: :kept_edit, cents: field_known?(field) ? (money_total(field) || fields.dig(field, "cents")) : nil, note: range_text(change))
    end

    def range_text(change)
      entry = change["total"] || Array(change["parts"]).first || change
      range = entry.to_h["range"]
      return "#{money(range.first)} to #{money(range.last)}" if range
      money(entry.to_h["amount_cents"]) if entry.to_h["amount_cents"]
    end

    def apply_text(field, value)
      limit = text_limit(field)
      text = value.to_s.squish
      return updates << Update.new(field: field, action: :too_long, cents: limit) if text.length > limit
      return if text.blank? || fields.dig(field, "value") == text
      fields[field] = { "value" => text }
      updates << Update.new(field: field, action: :set, label: text)
    end

    # A balance is what she has today, so cadence never applies.
    def apply_balance(field, change)
      cents = change["amount_cents"]
      return unless cents
      return if fields.dig(field, "cents") == cents
      fields[field] = { "cents" => cents }
      updates << Update.new(field: field, action: :total, cents: cents)
    end

    def apply_months(field, change)
      months = change["months"]
      return unless months
      fields[field] = { "value" => months }
      updates << Update.new(field: field, action: :set, label: months)
    end

    def apply_money(field, change)
      if change["none"]
        replace_with_total(field, 0, kind: "none")
        return updates << Update.new(field: field, action: :none)
      end
      parts = Array(change["parts"])
      total = change["total"]
      fields.delete(field) if change["replace_all"] && (parts.any? || total)
      remainder = nil
      if total && parts.any?
        parts_cents = counted_sum(parts)
        if total["total_marker"] && parts_cents == total["amount_cents"]
          total = nil
        elsif parts.any? { |part| part["amount_cents"] == total["amount_cents"] } || parts_cents > total["amount_cents"] || total["cadence"] != "monthly" || parts.any? { |part| part["cadence"] != "monthly" }
          total = nil
          needs = true
        elsif parts_cents == total["amount_cents"]
          total = nil
        else
          # "bills bout 2000, rent is 1500 of that": rent plus the rest.
          remainder = total["amount_cents"] - parts_cents
          total = nil
          fields.delete(field)
        end
      end
      if total
        apply_total(field, total)
      elsif needs
        fields[field] = { "parts" => parts.filter_map { |entry| money_part(entry.merge("label" => entry["label"] || default_label(field)), forced_unclear: true) } }
        updates << Update.new(field: field, action: :needs_monthly, note: "those numbers don't add up")
      else
        parts.each { |part| apply_money_part(field, part) }
        add_remainder(field, remainder) if remainder
      end
      offer_monthly(field)
      fields.delete(field) if fields.dig(field, "parts") == []
    end

    def add_remainder(field, cents)
      state = fields[field] ||= { "parts" => [] }
      state["parts"] << { "id" => new_id, "label" => other_label(field), "cents" => cents, "cadence" => "monthly", "counted" => true, "kind" => "remainder" }
      updates << Update.new(field: field, action: :added, label: other_label(field), cents: cents)
    end

    # The first figure that isn't a month yet becomes one plain question.
    def offer_monthly(field)
      return if offer(field) || needs_frequency?(field)
      part = proposable_part(field)
      return unless part
      proposal = propose_monthly(field)
      updates << Update.new(field: field, action: :offer, label: part["label"], cents: proposal[:monthly_cents], note: part["offer_question"])
    end

    def offer_question(part, proposal)
      monthly = money(proposal[:monthly_cents])
      if proposal[:kind] == :range
        "Want to use #{monthly} for now? You can change it any time."
      elsif proposal[:times] == 24
        "That's #{monthly} a month (#{plain(proposal[:stated_cents])} × 2). Use #{monthly}?"
      elsif proposal[:times] == 1
        "That's #{proposal[:exact] ? '' : 'about '}#{monthly} a month (#{plain(proposal[:stated_cents])} ÷ 12). Use #{monthly}?"
      else
        # Some months have an extra paycheck, so a weekly rhythm is "about".
        "That's about #{monthly} a month (#{plain(proposal[:stated_cents])} × #{proposal[:times]} ÷ 12). Use #{monthly}?"
      end
    end

    def proposal_note(part, proposal)
      monthly = money(proposal[:monthly_cents])
      return "#{money(proposal[:low_cents])} to #{money(proposal[:high_cents])}, #{monthly} if that's right" if proposal[:kind] == :range
      "#{stated_note(part['stated_cents'], part['cadence'])}, about #{monthly} a month if that's right"
    end

    def counted_sum(parts)
      parts.select { |part| part["cadence"].in?(%w[monthly]) }.sum { |part| part["amount_cents"].to_i }
    end

    def apply_total(field, total)
      if total["cadence"] == "monthly" || (total["cadence"] == "per_paycheck" && total["count"] && !pay_offer?(field, total))
        cents = total["amount_cents"] * (total["count"] || 1)
        replace_with_total(field, cents, kind: total["cadence"] == "per_paycheck" ? "paychecks" : "total", note: total["count"] && paycheck_note(total))
        updates << Update.new(field: field, action: :total, cents: cents, note: total["count"] && paycheck_note(total))
      else
        total = total.merge("cadence" => "twice_monthly", "stated_cents" => total["amount_cents"]) if pay_offer?(field, total)
        part = money_part(total.merge("label" => default_label(field)))
        fields[field] = { "parts" => [ part ] }
        updates << Update.new(field: field, action: :needs_monthly, label: default_label(field), note: part["note"]) unless proposable_part(field)
      end
    end

    # Twice-a-month pay is offered as a month like any other pay rhythm.
    def pay_offer?(field, entry) = REGISTRY.fetch(field).proposes_pay? && entry["stated_cadence"] == "twice_monthly"

    def paycheck_note(total)
      "#{total['count']} paychecks of #{money(total['amount_cents'])}"
    end

    def replace_with_total(field, cents, kind:, note: nil)
      fields[field] = { "parts" => [ { "id" => new_id, "label" => TOTAL_LABEL, "cents" => cents, "cadence" => "monthly", "counted" => true, "kind" => kind, "note" => note } ] }
      mark_saved_bills_removed(field) if kind == "total" && field.in?(BILL_FIELDS)
    end

    # A new overall total replaces separately saved bills, and the card says so.
    def mark_saved_bills_removed(field)
      saved = saved_bill_parts(field)
      return unless saved.length > 1
      fields[field]["parts"].first["label"] = free_total_label(field)
      fields[field]["parts"].first["kind"] = "part"
      fields[field]["parts"].concat(saved.map { |part| part.merge("removed" => true) })
    end

    def apply_money_part(field, entry)
      return apply_removal(field, entry["label"]) if entry["op"] == "remove"
      state = fields[field] ||= { "parts" => [] }
      seeded = state["parts"].empty?
      existing = carried_or_saved_parts(field, state)
      live = existing.reject { |part| part["removed"] }
      unlabeled = entry["label"].blank?
      label = entry["label"].presence || "#{default_label(field)} #{live.length + 1}"
      match = matching_part(existing, label, exact: entry["op"] == "add") unless unlabeled
      entry = entry.merge("cadence" => "twice_monthly", "stated_cents" => entry["amount_cents"]) if pay_offer?(field, entry)
      new_part = money_part(entry.merge("label" => label))
      combined = match if match && combined_row?(match, label)
      combined ||= live.find { |part| combined_row?(part, label) && (label_words(label) - label_words(part["label"])).empty? } unless match || unlabeled
      return updates << Update.new(field: field, action: :combined, label: label, note: combined["label"]) if combined
      if !match && live.length >= MAX_PARTS
        return updates << Update.new(field: field, action: :card_full, label: label)
      end
      if match
        index = state["parts"].index(match)
        new_part["id"] = match["id"]
        new_part["saved_label"] = match["saved_label"] if match["saved_label"]
        new_part["label"] = match["label"] if match["saved_label"]
        state["parts"][index] = new_part
      elsif (lump = live.select { |part| lump?(part) }).any? && !unlabeled && (entry["op"] == "replace" || entry["source"].to_s.match?(CHANGED_WORDS))
        fields.delete(field) if seeded
        return updates << Update.new(field: field, action: :no_breakdown, label: label, cents: lump.sum { |part| part["cents"].to_i })
      else
        state["parts"] << new_part
      end
      action = new_part["counted"] ? (match && !match["removed"] ? :changed : :added) : :needs_monthly
      updates << Update.new(field: field, action: action, label: new_part["label"], cents: new_part["counted"] ? new_part["cents"] : nil, note: new_part["note"]) unless action == :needs_monthly && proposable_part(field).equal?(new_part)
    end

    def apply_removal(field, label)
      state = fields[field] ||= { "parts" => [] }
      seeded = state["parts"].empty?
      existing = carried_or_saved_parts(field, state)
      live = existing.reject { |part| part["removed"] }
      match = matching_part(live, label, exact: false)
      unless match
        if (lump = live.select { |part| lump?(part) }).any?
          fields.delete(field) if seeded
          return updates << Update.new(field: field, action: :no_breakdown, label: label, cents: lump.sum { |part| part["cents"].to_i })
        end
        fields.delete(field) if seeded || state["parts"].empty?
        return updates << Update.new(field: field, action: :not_found, label: label)
      end
      return updates << Update.new(field: field, action: :combined, label: label, note: match["label"]) if combined_row?(match, label)
      match["saved_label"] ? match["removed"] = true : state["parts"].delete(match)
      if state["parts"].empty? && saved_totals[field]
        fields[field] = { "parts" => [] }
        return updates << Update.new(field: field, action: :no_breakdown, label: label, cents: saved_totals[field])
      end
      updates << Update.new(field: field, action: :removed, label: match["label"], cents: match["cents"])
    end

    # Saved money enters the card only once a part is added to it: named bills
    # by name, one total labelled plainly so the addition is visible.
    def carried_or_saved_parts(field, state)
      if state["parts"].empty?
        saved = field.in?(BILL_FIELDS) ? saved_bill_parts(field) : []
        if saved.any?
          state["parts"] = saved.map(&:deep_dup)
        elsif saved_totals[field]&.positive?
          state["parts"] = [ { "id" => new_id, "label" => SAVED_TOTAL_LABEL, "cents" => saved_totals[field], "cadence" => "monthly", "counted" => true, "kind" => "saved_total" } ]
        end
      end
      state["parts"]
    end

    # Each active budget row in this layer, as she can name it. One row with a
    # whole-layer name is a total, not a list.
    def saved_bill_parts(field)
      @saved_bill_parts ||= {}
      @saved_bill_parts[field] ||= begin
        items = household.expense_items.where(active: true, stack_key: REGISTRY.stack_key(field)).where.not(cadence: "one_time").order(:id).to_a
        parts = items.map do |item|
          cents = Money.monthly_cents(item.amount_cents, item.cadence)
          aggregate = AGGREGATE_LABELS.include?(item.label.to_s.downcase)
          { "id" => "saved-#{item.id}", "label" => aggregate && items.one? ? SAVED_TOTAL_LABEL : item.label, "saved_label" => item.label, "cents" => cents, "saved_cents" => cents,
            "cadence" => "monthly", "counted" => true, "kind" => aggregate && items.one? ? "saved_total" : "part" }
        end
        parts.reject { |part| part["cents"].zero? && parts.length > 1 }
      end
    end

    # One figure with no named bills inside it, including a saved whole-layer
    # row that sits beside named ones.
    def lump?(part) = LUMP_KINDS.include?(part["kind"]) || AGGREGATE_LABELS.include?(part["saved_label"].to_s.downcase)

    def money_part(entry, forced_unclear: false)
      cadence = forced_unclear ? "unclear" : entry["cadence"]
      cents = entry["amount_cents"]
      # "groceries 150 twice a month" is a known count, so it is a month.
      count = entry["count"].to_i if cadence == "per_paycheck" && entry["count"].to_i.positive?
      return counted_part(entry, cents * count, count_note(cents, count)) if count

      counted = cadence == "monthly"
      extra = entry["needs_frequency"] && !counted ? { "needs_frequency" => true } : {}
      extra["range"] = entry["range"] if entry["range"] && !counted && !forced_unclear
      extra.merge({ "id" => new_id, "label" => entry["label"].to_s.sub(/\A./, &:upcase), "cents" => counted ? cents : nil, "cadence" => cadence, "counted" => counted, "kind" => "part",
        "stated_cents" => counted ? nil : cents, "note" => counted ? nil : stated_note(cents, cadence, entry["range"]) })
    end

    def counted_part(entry, cents, note)
      { "id" => new_id, "label" => entry["label"].to_s.sub(/\A./, &:upcase), "cents" => cents, "cadence" => "monthly", "counted" => true, "kind" => "part", "stated_cents" => nil, "note" => note }
    end

    def count_note(cents, count) = count == 2 ? "#{money(cents)} twice a month" : "#{count} times #{money(cents)} a month"

    def stated_note(cents, cadence, range = nil)
      return "#{money(range.first)} to #{money(range.last)}, not sure which" if range
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

    def default_label(field) = REGISTRY.fetch(field).default_label
    def other_label(field) = REGISTRY.fetch(field).other_label || "Other"
    def default_total_label(field) = CARD_LABELS.fetch(field)

    # A new whole-layer total needs a budget row name that isn't already used,
    # including by a row archived when the bills were split.
    def free_total_label(field)
      taken = household.budget_categories.pluck(:name).map(&:downcase)
      [ default_total_label(field), other_label(field), "All #{default_total_label(field).downcase}" ].find { |label| !taken.include?(label.downcase) } || default_total_label(field)
    end

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
      return edit_months(field, value) if field.in?(MONTHS_FIELDS)
      cents = edited_cents(value)
      return fields[field] = { "cents" => cents } if field.in?(BALANCE_FIELDS)
      return edit_debt(part_id, cents) if field == DEBT_FIELD
      state = fields[field] ||= { "parts" => [] }
      if part_id.present?
        part = state["parts"].find { |row| row["id"] == part_id }
        raise ArgumentError, "That row changed. Look at your card again." unless part
        part.replace(part.except("proposed_cents", "needs_frequency", "removed", "range", "offered", "parked", "offer_question").merge("cents" => cents, "cadence" => "monthly", "counted" => true, "note" => nil, "stated_cents" => nil, "kind" => part["kind"] == "saved_total" ? "part" : part["kind"]))
      else
        state["parts"] = [ { "id" => new_id, "label" => TOTAL_LABEL, "cents" => cents, "cadence" => "monthly", "counted" => true, "kind" => "total" } ]
        mark_saved_bills_removed(field) if field.in?(BILL_FIELDS)
      end
    end

    def edited_cents(value)
      text = value.to_s.strip
      raise ArgumentError, "Enter an amount like 1500." if text.match?(ParticipantMessageReader::MISPLACED_COMMA)
      cents = Money.cents!(text.delete(",$"), message: "Enter an amount like 1500.")
      raise ArgumentError, "Enter an amount of $0 or more." if cents.negative?
      raise ArgumentError, "That amount is too large." if cents > Money::MAX_AMOUNT_CENTS
      cents
    end

    def edit_months(field, value)
      months = BigDecimal(value.to_s.strip)
      raise ArgumentError, "Enter a number of months, like 3." unless months.positive? && months <= REGISTRY::MAX_RUNWAY_MONTHS
      fields[field] = { "value" => months.frac.zero? ? months.to_i.to_s : months.to_s("F") }
    rescue ArgumentError, TypeError
      raise ArgumentError, "Enter a number of months, like 3."
    end

    def text_limit(field) = REGISTRY::MAX_TEXT.fetch(field)

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
        part.delete("removed")
        part["changed"] = true if part["saved"]
      else
        raise ArgumentError, "Change each debt on its own row." if state["parts"].any? { |row| !row["placeholder"] && !row["removed"] }
        state["parts"].reject! { |row| row["placeholder"] }
        state["total_cents"] = cents
      end
    end

    def edit_remove(field, part_id)
      state = fields[field]
      return fields.delete(field) if state && !field.in?(MONEY_FIELDS) && field != DEBT_FIELD
      return unless state
      if field == DEBT_FIELD
        return fields.delete(field) if part_id.blank?
        part = Array(state["parts"]).find { |row| row["id"] == part_id }
        return unless part
        part["saved"] ? part["removed"] = true : state["parts"].delete(part)
        fields.delete(field) if state["parts"].empty?
      elsif part_id.blank?
        fields.delete(field)
      else
        part = Array(state["parts"]).find { |row| row["id"] == part_id }
        return unless part
        part["saved_label"] ? part["removed"] = true : state["parts"].delete(part)
        fields.delete(field) if state["parts"].empty? || state["parts"].all? { |row| row["saved_label"] && !row["removed"] && row["cents"] == row["saved_cents"] }
      end
    end

    def row_for(field)
      case REGISTRY.kind(field)
      when :text then text_row(field)
      when :balance then balance_row(field)
      when :months then months_row(field)
      when :debts then debt_row
      else money_row(field)
      end
    end

    def text_row(field)
      base_row(field, status: "entered", value_text: fields.dig(field, "value"), kind: "text")
    end

    def balance_row(field)
      base_row(field, status: "entered", kind: "money", total_cents: fields.dig(field, "cents"))
    end

    def months_row(field)
      value = fields.dig(field, "value")
      base_row(field, status: "entered", kind: "months", value_text: "#{value} #{value == '1' ? 'month' : 'months'}")
    end

    def money_row(field)
      state = fields[field]
      rows = Array(state["parts"])
      total = money_total(field)
      status = unresolved?(field) ? "needs_monthly" : "entered"
      note = "#{unresolved_labels(field).to_sentence} #{unresolved_labels(field).one? ? 'needs' : 'need'} a monthly amount." if unresolved?(field)
      shown = rows.reject { |part| part["saved_label"] && !part["removed"] && part["cents"] == part["saved_cents"] }
      unchanged = rows - shown
      # One stated total is the row itself; a sub-row would only repeat it.
      single_total = shown.one? && shown.first["counted"] && shown.first["kind"] != "part" && shown.first["kind"] != "remainder"
      note ||= shown.first["note"] if single_total
      note ||= "#{unchanged.map { |part| part['label'] }.to_sentence} #{unchanged.one? ? 'stays' : 'stay'} as #{unchanged.one? ? 'it is' : 'they are'}." if unchanged.any? && unchanged.length <= 3
      note ||= "Your other #{unchanged.length} stay as they are." if unchanged.any?
      base_row(field, status: status, kind: "money", total_cents: total, parts: single_total ? [] : shown.map { |part| money_row_part(part) }, note: note)
    end

    def money_row_part(part)
      return { id: part["id"], label: part["label"], cents: part["saved_cents"], counted: true, note: "Taking this off", removable: false, removed: true } if part["removed"]
      { id: part["id"], label: part["label"], cents: part["cents"], counted: part["counted"], note: part["note"], removable: true }
    end

    def debt_row
      state = fields[DEBT_FIELD]
      return base_row(DEBT_FIELD, status: "entered", kind: "debts", value_text: "No debts") if state["none"]
      parts = Array(state["parts"]).filter_map do |part|
        next if part["saved"] && !part["changed"] && !part["removed"]
        next { id: part["id"], label: part["name"], cents: part["saved_minimum_cents"], counted: true, note: "Paid off, taking this off", removable: false, removed: true } if part["removed"]
        { id: part["id"], label: part["name"], cents: part["minimum_cents"], counted: part["minimum_cents"].present?,
          note: part["minimum_cents"].nil? ? (part["minimum_note"] || "needs a minimum") : (part["balance_cents"] ? "#{money(part['balance_cents'])} balance" : nil), removable: true }
      end
      live = Array(state["parts"]).reject { |part| part["removed"] }
      total = state["total_cents"] || (live.any? && live.all? { |part| part["minimum_cents"] } ? live.sum { |part| part["minimum_cents"] } : (live.empty? && Array(state["parts"]).any? ? 0 : nil))
      base_row(DEBT_FIELD, status: debt_known? || live.empty? ? "entered" : "needs_monthly", kind: "debts", total_cents: total, parts: parts,
        note: debts_without_minimum.any? ? "#{debts_without_minimum.to_sentence} #{debts_without_minimum.one? ? 'needs' : 'need'} a monthly minimum." : nil)
    end

    def base_row(field, status:, kind:, value_text: nil, total_cents: nil, parts: [], note: nil)
      { key: field, label: CARD_LABELS.fetch(field), kind: kind, status: status,
        value_text: value_text, total_cents: total_cents, parts: parts, note: note }
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
      return [ saved_totals[field], saved_bill_parts(field).map { |part| [ part["saved_label"], part["cents"] ] } ] if field.in?(BILL_FIELDS)
      return saved_totals[field] if field.in?(MONEY_FIELDS)
      return DataPresenter.new(household).setup_values[field.to_sym].to_s if field.in?(BALANCE_FIELDS) || field.in?(MONTHS_FIELDS)
      portfolio = DebtPortfolio.new(household)
      [ portfolio.minimum_payment_known?, portfolio.monthly_minimum_cents, portfolio.active_debts.length ]
    end

    def new_id = SecureRandom.hex(4)

    def plain(cents) = ActiveSupport::NumberHelper.number_to_delimited(Money.dollars(cents).to_i == Money.dollars(cents) ? Money.dollars(cents).to_i : Money.dollars(cents))

    def money(cents)
      ActiveSupport::NumberHelper.number_to_currency(Money.dollars(cents), precision: cents % 100 == 0 ? 0 : 2)
    end
  end
end
