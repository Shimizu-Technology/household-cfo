module HouseholdFinance
  # Changing, recategorizing or removing a purchase she already confirmed, from
  # the chat. Ruby finds the purchase and works out the change; nothing moves
  # until she approves the card. Approving reopens the purchase and confirms it
  # again through the same operations the Spending screen uses, so the old
  # entry stays in her history.
  class PurchaseChange
    MAX_CHOICES = 3
    HISTORY_DAYS = 400
    # attributes: what the review card is built from, or nil when Mia only replies.
    Plan = Data.define(:reply, :mode, :attributes)
    Stale = Class.new(StandardError)

    def self.plan(household:, message:, today: Date.current)
      request = PurchaseChangeRequest.parse(message, today: today)
      return unless request

      new(household, request, message: message, today: today).plan
    end

    # She picked one of the purchases Mia listed.
    def self.for_choice(household:, change:, transaction_draft_id:, today: Date.current)
      request = PurchaseChangeRequest::Result.new(void: change["void"] == true, new_cents: change["new_cents"], old_cents: nil, category_text: nil, day: nil)
      draft = household.transaction_drafts.find_by(id: transaction_draft_id)
      return unless draft&.status.in?(%w[confirmed corrected])

      category = household.budget_categories.active.find_by(id: change["category_id"]) if change["category_id"]
      new(household, request, message: "", today: today).confirm(draft, category)
    end

    # The review card. Asking again about the same purchase replaces the card
    # she hasn't answered yet.
    def self.create_draft!(plan, household:, user:, user_message:, assistant_message:, cohort_membership: nil)
      supersede_open_cards!(household, user, user_message, cohort_membership)
      proposal(plan, household: household, user: user, source_prompt: user_message.content)
        .create_draft!(source_chat_message: user_message, assistant_chat_message: assistant_message, allow_empty: true)
    end

    def self.proposal(plan, household:, user:, source_prompt:)
      attributes = plan.attributes
      items = attributes.fetch(:items).map do |item|
        MiaActionDraftBuilder::Item.new(**item, source_text: nil, source_start: nil, source_end: nil, dependencies: [])
      end
      MiaActionDraftBuilder::Proposal.new(household: household, user: user, year: attributes.fetch(:year), draft_type: "purchase_change",
        title: attributes.fetch(:title), summary: attributes.fetch(:summary), rationale: "", source_prompt: source_prompt, items: items,
        metadata: { source: "mia_chat", parser: "purchase_change", purchase_change: attributes.fetch(:detail) })
    end

    def self.supersede_open_cards!(household, user, source_message, cohort_membership)
      household.mia_action_drafts.pending.where(draft_type: "purchase_change", requested_by_user: user).joins(:source_chat_message)
        .where(chat_messages: { chat_session_id: source_message.chat_session_id }).find_each do |previous|
        result = MiaActionDraftCanceler.new(previous, user: user, cohort_membership: cohort_membership).call(idempotency_key: "superseded:#{previous.id}:#{source_message.id}")
        raise ArgumentError, result.errors.join(", ") unless result.success?
      end
    end
    private_class_method :supersede_open_cards!

    def self.snapshot(draft)
      transaction = draft.confirmed_transaction
      { "draft_id" => draft.id, "status" => draft.status, "transaction_id" => transaction&.id, "transaction_status" => transaction&.status,
        "occurred_on" => draft.occurred_on.iso8601, "merchant" => draft.merchant, "amount_cents" => draft.total_amount_cents,
        "splits" => draft.transaction_draft_splits.order(:id).map { |split| { "id" => split.id, "category_id" => split.budget_category_id, "amount_cents" => split.amount_cents } } }
    end

    # Reopens the confirmed purchase and either confirms it again with her
    # change or leaves it out of spending. Runs inside the apply transaction.
    def self.apply!(household:, user:, cohort_membership:, payload:, before:, key:)
      draft = household.transaction_drafts.lock.find(payload.fetch("transaction_draft_id"))
      unless draft.status.in?(%w[confirmed corrected]) && snapshot(draft) == before.deep_stringify_keys
        raise Stale, "That purchase changed since I prepared this. Ask me again and I'll look at it fresh. Nothing changed."
      end

      runner = Operations::Runner.new(household, user: user, cohort_membership: cohort_membership)
      runner.run(operation_key: "transaction.draft.reopen", input: { draft_id: draft.id, source_type: "manual_chat" },
        idempotency_key: "#{key}:reopen", source: "mia")
      if payload["void"]
        runner.run(operation_key: "transaction.draft.ignore", input: { draft_id: draft.id, source_type: "manual_chat" },
          idempotency_key: "#{key}:ignore", source: "mia")
      else
        split = draft.transaction_draft_splits.reload.order(:id).sole
        amount = payload.fetch("new_amount_cents").to_i
        dollars = format("%d.%02d", amount / 100, amount % 100)
        runner.run(operation_key: "transaction.draft.confirm", idempotency_key: "#{key}:confirm", source: "mia",
          input: { draft_id: draft.id, source_type: "manual_chat", amount: dollars,
                   splits: [ { id: split.id, budget_category_id: payload["new_category_id"] || split.budget_category_id, amount: dollars } ] })
      end
    end

    def initialize(household, request, message:, today:)
      @household = household
      @request = request
      @text = message.to_s.downcase.squish
      @today = today
    end

    def plan
      pool = candidates
      return if pool.empty?
      # A purchase still waiting for her review is edited by its own card. Only
      # a figure that pins a confirmed one lets this take the message.
      return if pending_purchase_named? && !(request.old_cents && pool.any? { |draft| draft.total_amount_cents == request.old_cents })

      changeable = pool.reject { |draft| draft.financial_source_event_id.present? }
      return reply_only("That purchase came from a statement line, so I can't change it from chat. Open Statements to fix that line. Nothing changed.") if changeable.empty?

      category = nil
      if request.category_text.present?
        category = resolve_category(request.category_text)
        return reply_only("Which category should it go in? #{category_examples} Nothing changed.".squish) unless category
      end
      return choose(changeable, category) if changeable.length > 1

      confirm(changeable.first, category)
    end

    def confirm(draft, category)
      transaction = draft.confirmed_transaction
      split = draft.transaction_draft_splits.first
      if (draft.transaction_draft_splits.many? || transaction.transaction_splits.many?) && !request.void
        return reply_only("That purchase is split across categories, so change it on the Spending screen where you can see each part. Nothing changed.")
      end

      new_cents = request.void ? nil : (request.new_cents || draft.total_amount_cents)
      new_category = request.void ? nil : (category || split&.budget_category)
      unless request.void
        return reply_only("That purchase needs a category before I can move it. Tell me which one. Nothing changed.") if new_category.nil?
        if new_cents == draft.total_amount_cents && new_category.id == split&.budget_category_id
          return reply_only("#{draft.merchant} on #{day_label(draft.occurred_on)} already says #{money(draft.total_amount_cents)} in #{new_category.name}. Nothing changed.")
        end
      end

      rows = []
      if !request.void && new_cents != draft.total_amount_cents
        rows << { "label" => "Amount", "before" => money(draft.total_amount_cents), "after" => money(new_cents) }
      end
      if !request.void && new_category.id != split&.budget_category_id
        rows << { "label" => "Category", "before" => split&.budget_category&.name || "No category", "after" => new_category.name }
      end
      found = "I found your #{draft.merchant} purchase of #{money(draft.total_amount_cents)} from #{day_label(draft.occurred_on)}."
      reply = if request.void
        "#{found} I can take it out of your spending; it stays in your history as removed. Nothing changes until you tap Yes on the card."
      else
        "#{found} I can change its #{rows.map { |row| row['label'].downcase }.to_sentence}. Check the card, then tap Yes. Nothing changes until you do."
      end
      payload = { "transaction_draft_id" => draft.id, "void" => request.void }
      payload.merge!("new_amount_cents" => new_cents, "new_category_id" => new_category.id) unless request.void
      item = {
        action_type: "change_purchase",
        label: request.void ? "Remove #{draft.merchant} from spending" : "Change #{draft.merchant}",
        description: request.void ? "#{draft.merchant} #{money(draft.total_amount_cents)} · #{day_label(draft.occurred_on)}" : rows.map { |row| "#{row['label']}: #{row['before']} → #{row['after']}" }.join("; "),
        payload: payload, before_snapshot: self.class.snapshot(draft), after_snapshot: {},
        target_record_type: "TransactionDraft", target_record_id: draft.id
      }
      detail = { "mode" => "confirm", "merchant" => draft.merchant, "date_label" => day_label(draft.occurred_on), "void" => request.void,
                 "amount" => money(draft.total_amount_cents), "rows" => rows, "effects" => budget_effects(draft, new_cents: new_cents, new_category: new_category),
                 "note" => request.void ? "It leaves your spending totals. The entry stays in your history as removed." : "The old entry stays in your history." }
      Plan.new(reply: reply, mode: "confirm", attributes: {
        items: [ item ], year: draft.occurred_on.year, title: request.void ? "Remove this purchase?" : "Change this purchase?",
        summary: "#{draft.merchant} · #{money(draft.total_amount_cents)} · #{day_label(draft.occurred_on)}", detail: detail
      })
    end

    private

    attr_reader :household, :request, :text, :today

    # Her confirmed purchases that the message points at: the merchant is
    # named, narrowed by the amount or day when she gave them.
    def candidates
      named = base_scope.to_a.select { |draft| merchant_named?(draft.merchant) }
      return [] if named.empty?

      narrowed = named
      if request.old_cents && narrowed.any? { |draft| draft.total_amount_cents == request.old_cents }
        narrowed = narrowed.select { |draft| draft.total_amount_cents == request.old_cents }
      end
      if request.day && narrowed.any? { |draft| draft.occurred_on == request.day }
        narrowed = narrowed.select { |draft| draft.occurred_on == request.day }
      end
      narrowed
    end

    def pending_purchase_named?
      household.transaction_drafts.pending.limit(50).any? { |draft| merchant_named?(draft.merchant) }
    end

    def base_scope
      household.transaction_drafts.where(status: %w[confirmed corrected])
        .joins(:confirmed_transaction).where(household_transactions: { status: "confirmed" })
        .where("transaction_drafts.occurred_on >= ?", today - HISTORY_DAYS)
        .includes(:transaction_draft_splits, :budget_category, confirmed_transaction: :transaction_splits)
        .recent_first.limit(300)
    end

    def merchant_named?(merchant)
      words = merchant.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").split
      keys = [ words.join(" "), words.first(2).join(" ") ]
      keys << words.first if words.first.to_s.length >= 4
      keys.reject(&:blank?).uniq.any? { |key| text.match?(/(?<![a-z0-9])#{Regexp.escape(key)}s?(?![a-z0-9])/) }
    end

    def choose(drafts, category)
      shown = drafts.first(MAX_CHOICES)
      options = shown.map { |draft| { "transaction_draft_id" => draft.id, "label" => "#{draft.merchant} · #{money(draft.total_amount_cents)} · #{day_label(draft.occurred_on)}" } }
      lead = drafts.length > MAX_CHOICES ? "I found #{drafts.length} purchases that could be the one; here are the #{MAX_CHOICES} most recent." : "I found #{drafts.length} purchases that could be the one."
      Plan.new(reply: "#{lead} Which one do you mean? Nothing has changed.", mode: "choose", attributes: {
        items: [], year: shown.first.occurred_on.year, title: "Which purchase?", summary: "Choose the purchase you mean",
        detail: { "mode" => "choose", "options" => options, "void" => request.void,
                  "change" => { "void" => request.void, "new_cents" => request.new_cents, "category_id" => category&.id } }
      })
    end

    def reply_only(message)
      Plan.new(reply: message, mode: "none", attributes: nil)
    end

    def resolve_category(name_text)
      active = household.budget_categories.active.to_a
      wanted = normalize_name(name_text)
      exact = active.find { |category| normalize_name(category.name) == wanted }
      return exact if exact

      stem = stem_of(wanted)
      found = active.select do |category|
        name = normalize_name(category.name)
        stem_of(name).start_with?(stem) || stem.start_with?(stem_of(name)) || name.include?(wanted)
      end
      found.one? ? found.first : nil
    end

    def normalize_name(value)
      value.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").squish
    end

    def stem_of(value)
      value.sub(/ies\z/, "y").sub(/s\z/, "")
    end

    def category_examples
      names = household.budget_categories.active.order(:sort_order, :name).limit(4).pluck(:name)
      names.any? ? "For example #{names.to_sentence(two_words_connector: ' or ', last_word_connector: ', or ')}." : ""
    end

    # What the month's category looks like after the change.
    def budget_effects(draft, new_cents:, new_category:)
      year = draft.occurred_on.year
      return [] unless AnnualBudgetManager.supported_year?(year)

      rows = Array(AnnualBudgetManager.new(household, year: year).plan_data[:rows])
      month = draft.occurred_on.month
      before = draft.transaction_draft_splits.map { |split| [ split.budget_category_id, split.amount_cents ] }
      after = new_cents ? [ [ new_category&.id, new_cents ] ] : []
      (before.map(&:first) + after.map(&:first)).compact.uniq.filter_map do |id|
        row = rows.find { |candidate| (candidate[:id] || candidate["id"]).to_i == id }
        cell = row && Array(row[:months] || row["months"])[month - 1]
        next unless cell

        actual = Money.cents(cell[:actual] || cell["actual"])
        planned = Money.cents(cell[:planned] || cell["planned"])
        updated = actual - before.sum { |category_id, cents| category_id == id ? cents : 0 } + after.sum { |category_id, cents| category_id == id ? cents : 0 }
        effect_line(row[:name] || row["name"], draft.occurred_on, actual, updated, planned)
      end
    rescue StandardError => error
      Rails.logger.warn("Purchase change budget effect skipped: #{error.class}: #{error.message}")
      []
    end

    def effect_line(name, date, before, after, planned)
      left = planned - after
      detail = if planned.positive?
        left >= 0 ? "#{money(after)} spent of your #{money(planned)} plan, #{money(left)} left" : "#{money(after)} spent, #{money(-left)} over your #{money(planned)} plan"
      else
        "#{money(after)} spent"
      end
      "#{name}, #{date.strftime('%B')}: #{detail} (was #{money(before)} spent)."
    end

    def day_label(date)
      date.year == today.year ? date.strftime("%a, %b %-d") : date.strftime("%b %-d, %Y")
    end

    def money(cents)
      ActiveSupport::NumberHelper.number_to_currency(Money.dollars(cents), precision: cents.to_i % 100 == 0 ? 0 : 2)
    end
  end
end
