module HouseholdFinance
  # One participant message against the setup card. Nothing is written until
  # commit!, which runs alongside the chat messages so they save together.
  class MiaSetupCardTurn
    OFF_REPLY = "I can't read setup answers just now, and nothing was saved. Please try again in a moment, or tap Enter my numbers to keep going.".freeze
    KEEP_GOING = "Take your time.".freeze
    RESUMED = "Of course, let's keep going.".freeze
    UNKNOWN_MINIMUM = /\b(?:idk|dont know|don['’]?t know|not sure|no idea)\b/i
    BARE_YES = /\A(?:yes|yeah|yea|yep|ya|sure|correct|right|ok(?:ay)?|that works|sounds (?:good|right)|use (?:it|that))[\s.!]*\z/i
    TITLE = "Your setup so far".freeze
    Plan = Data.define(:reply, :update_text, :continues, :next_field, :work_out) do
      def initialize(work_out: nil, **rest) = super
    end
    Commit = Data.define(:draft, :created)

    class << self
      def card_draft(household, user:, session:)
        # Clear chat detaches the card from its message, but it is still her card.
        household.mia_action_drafts.pending.where(draft_type: "household_setup", requested_by_user: user)
          .where("mia_action_drafts.metadata ? 'setup_card'").left_outer_joins(:source_chat_message)
          .where("chat_messages.chat_session_id = :session OR mia_action_drafts.source_chat_message_id IS NULL", session: session.id).recent_first.first
      end

      def open?(household, user:, session:)
        SetupStatus.new(household).missing_field_keys.any? || card_draft(household, user: user, session: session).present?
      end

      def active_field(session) = session.active_topic.to_h["setup_card_field"].presence_in(MiaSetupCard::FIELDS)

      def reader_context(household, user:, session:)
        card = load_card(household, user: user, session: session)
        { saved: saved_values(household), draft: draft_rows(card), skipped: Array(household.setup_skipped_fields), last_asked: active_field(session).to_s,
          paycheck_help: session.active_topic.to_h["setup_card_work_out"].present? }
      end

      # What she can change by name once setup is done and no card is open.
      def saved_bills(household, user:, session:)
        return if SetupStatus.new(household).missing_field_keys.any? || card_draft(household, user: user, session: session)
        load_card(household, user: user, session: session).saved_bill_labels
      end

      # The first field still open once a card row or skip has changed.
      def next_open_field(household, card, new_skips: [], status: SetupStatus.new(household), except: [])
        skipped = Array(household.setup_skipped_fields) + new_skips + except
        open = (status.missing_field_keys - skipped).reject { |field| card.field_known?(field) }
        (card.unresolved_field_keys - skipped).first || open.first
      end

      def load_card(household, user:, session:)
        draft = card_draft(household, user: user, session: session)
        return MiaSetupCard.new(household, state: draft.metadata["setup_card"]) if draft
        card = MiaSetupCard.new(household)
        # The latest card that touched a field holds its breakdown, even when
        # a later card changed only something else.
        household.mia_action_drafts.where(draft_type: "household_setup", status: "applied", requested_by_user: user)
          .where("mia_action_drafts.metadata ? 'setup_card'").recent_first.limit(10)
          .each { |previous| card.carry_parts_from(previous.metadata["setup_card"]) }
        card
      end

      private

      def saved_values(household)
        confirmed = SetupStatus.new(household).confirmed_field_keys
        values = DataPresenter.new(household, ensure_plan: false).setup_values
        confirmed.index_with { |field| values[field.to_sym] }.compact
      end

      def draft_rows(card)
        card.rows.each_with_object({}) do |row, draft|
          next unless row[:status].in?(%w[entered needs_monthly])
          draft[row[:key]] = { value: row[:value_text], total_cents: row[:total_cents], parts: row[:parts].map { |part| part.slice(:label, :cents, :note) } }.compact
        end
      end
    end

    def initialize(household:, user:, session:, reading:, active_topic: session.active_topic.to_h, resuming: false, message: nil)
      @resuming = resuming
      @message = message.to_s
      @household = household
      @user = user
      @session = session
      @reading = reading
      @active_topic = active_topic
      @status = SetupStatus.new(household)
    end

    def plan
      return @plan if defined?(@plan)
      @plan = build_plan
    end

    def commit!(user_message:, assistant_message:)
      return unless plan
      persist_skips
      topic_field = plan.next_field
      @session.update!(active_topic: @session.active_topic.to_h.merge("setup_card_field" => topic_field, "setup_card_work_out" => plan.work_out))
      return unless @card_touched
      @commit = save_card(user_message, assistant_message)
    end

    def draft = @commit&.draft

    def card = @card ||= self.class.load_card(@household, user: @user, session: @session)

    private

    def build_plan
      asked = self.class.active_field(@session)
      unless @reading.available
        return Plan.new(reply: OFF_REPLY, update_text: nil, continues: false, next_field: asked) if asked || card_draft
        return
      end
      changes = @reading.setup_changes
      return unless changes
      waiting_on = @active_topic["setup_card_work_out"].presence_in(MiaSetupCard::MONEY_FIELDS)
      confirm_offered_monthly(changes, asked)
      updates = card.apply_changes(changes.except("skips", "help_topic", "work_out", "confirm_monthly"))
      card.apply_preferences(@reading.spending_preferences)
      @card_touched = card.updates.any? { |update| !update.action.in?(MiaSetupCard::NOOP_ACTIONS) }
      skipped = skip_fields(changes["skips"])
      update_text = [ MiaSetupCardReply.updated_text(card.updates, card, card_open: @card_touched || card_draft.present?).presence, MiaSetupCardReply.skipped_text(skipped) ].compact.join(" ")
      next_field = next_open_field(skipped)
      if waiting_on && (plan = paycheck_answer_plan(waiting_on, update_text, next_field))
        return plan
      end
      if update_text.present?
        return Plan.new(reply: nil, update_text: update_text, continues: true, next_field: next_field) if @reading.question
        return composed_plan(update_text, update_text, next_field, asked)
      end
      if (field = work_out_field(changes, asked))
        return work_out_plan(field, next_field)
      end
      return help_plan(changes["help_topic"], next_field) if changes["help_topic"]
      return if !@resuming && (@reading.question || @reading.facts.any? || !asked)
      composed_plan(@resuming ? RESUMED : KEEP_GOING, nil, next_field, asked)
    end

    def composed_plan(lead, update_text, next_field, asked)
      reply = compose(lead, next_field, asked: asked)
      Plan.new(reply: reply, update_text: update_text, continues: false, next_field: next_field, work_out: @frequency_asked)
    end

    # Agreement only counts as an answer to the figure Mia just offered.
    def confirm_offered_monthly(changes, asked)
      field = card.proposal_field
      card.confirm_proposed_monthly(field) if field && field == asked && (changes["confirm_monthly"] || @message.match?(BARE_YES))
    end

    def work_out_field(changes, asked)
      return unless changes["work_out"]
      (changes["help_topic"] || asked).presence_in(MiaSetupCard::MONEY_FIELDS)
    end

    # Help that calculates: the working if there is a figure to work from,
    # otherwise the amount and how often it comes.
    def work_out_plan(field, next_field)
      proposal = card.propose_monthly(field)
      return Plan.new(reply: MiaSetupCardReply::PAYCHECK_QUESTION, update_text: nil, continues: false, next_field: field, work_out: field) unless proposal

      @card_touched = true
      Plan.new(reply: MiaSetupCardReply.working(proposal), update_text: nil, continues: false, next_field: field)
    end

    # She was asked for one paycheck and how often. A lone amount is never a
    # month, and only an answer to that question is read as a frequency.
    def paycheck_answer_plan(field, update_text, next_field)
      if lone_paycheck?(field) && card.mark_paycheck_unclear(field)
        @card_touched = true
        return Plan.new(reply: MiaSetupCardReply::PAYCHECK_FREQUENCY_QUESTION, update_text: nil, continues: false, next_field: field, work_out: field)
      end
      frequency = ParticipantMessageReader.pay_frequency_answer(@message)
      return Plan.new(reply: MiaSetupCardReply::BIMONTHLY_QUESTION, update_text: nil, continues: false, next_field: field, work_out: field) if frequency == "bimonthly"
      if (count = { "twice_monthly" => 2, "monthly" => 1 }[frequency]) && (update = card.count_paychecks(field, count))
        @card_touched = true
        reply = MiaSetupCardReply.updated_text([ update ], card)
        following = next_open_field([])
        return Plan.new(reply: compose(reply, following, asked: field), update_text: reply, continues: false, next_field: following)
      end
      card.set_paycheck_cadence(field, frequency) if frequency
      return unless frequency || card.updates.any? { |update| update.field == field }
      proposal = card.propose_monthly(field)
      return unless proposal

      @card_touched = true
      Plan.new(reply: [ update_text.presence, MiaSetupCardReply.working(proposal) ].compact.join(" "), update_text: nil, continues: false, next_field: field)
    end

    def lone_paycheck?(field)
      card.updates.any? { |update| update.field == field && update.action == :total } &&
        !@message.match?(ParticipantCare::SETUP_FIELD_WORDS) && !@message.match?(/\b(?:twice|every)\b/i)
    end

    def help_plan(field, next_field)
      question = MiaSetupCardReply.question(field, card: card, previous: nil)
      Plan.new(reply: "#{MiaSetupCardReply.help(field)} #{question}", update_text: nil, continues: false, next_field: next_field || field)
    end

    def compose(lead, next_field, asked:)
      return lead if card.updates.any? { |update| update.action.in?(%i[no_breakdown combined too_long not_found]) }
      closing = frequency_question(next_field) || repeat_working(next_field, asked) || (next_field ? MiaSetupCardReply.question(next_field, card: card, previous: asked) : finish_text)
      first_save = "Nothing saves until you tap Apply." if @card_touched && !card_draft && next_field
      [ lead.presence, first_save, closing ].compact.join(" ")
    end

    # An amount with no stated frequency can't be worked out yet.
    def frequency_question(field)
      return unless field && card.needs_frequency?(field)
      @frequency_asked = field
      MiaSetupCardReply::PAYCHECK_FREQUENCY_QUESTION
    end

    # Asking the same unanswerable question twice is the loop; the working ends it.
    def repeat_working(next_field, asked)
      return unless next_field && next_field == asked && card.updates.none? { |update| update.field == next_field }
      proposal = card.propose_monthly(next_field)
      return unless proposal

      @card_touched = true
      MiaSetupCardReply.working(proposal)
    end

    def finish_text
      card.empty? ? "That's everything for now. Tell me whenever you want to add the rest." : MiaSetupCardReply.finished(card)
    end

    def card_draft = self.class.card_draft(@household, user: @user, session: @session)

    def skip_fields(skips)
      Array(skips).select { |field| open_for_skip?(field) }
    end

    def open_for_skip?(field)
      field.in?(MiaSetupCard::FIELDS) && @status.missing_field_keys.include?(field) && !card.field_known?(field)
    end

    # A row she just started and left unfinished comes before a new question,
    # unless she skipped it or just said she doesn't know the minimum.
    def next_open_field(new_skips)
      card.mark_minimum_unknown(card.updates.select { |update| update.field == MiaSetupCard::DEBT_FIELD && update.action == :added && update.cents.nil? }.map(&:label)) if @message.match?(UNKNOWN_MINIMUM)
      except = card.only_unknown_minimums_left? ? [ MiaSetupCard::DEBT_FIELD ] : []
      self.class.next_open_field(@household, card, new_skips: new_skips, status: @status, except: except)
    end

    def persist_skips
      skips = Array(plan_skips) | (Array(@household.setup_skipped_fields) - known_fields)
      @household.update!(setup_skipped_fields: skips) unless skips == Array(@household.setup_skipped_fields)
    end

    def plan_skips = @reading.setup_changes.to_h["skips"].then { |skips| skip_fields(skips) }

    def known_fields = MiaSetupCard::FIELDS.select { |field| card.field_known?(field) }

    def save_card(user_message, assistant_message)
      existing = card_draft
      draft = MiaSetupCardDraft.new(@household, user: @user, card: card).save!(user_message: user_message, assistant_message: assistant_message, existing: existing)
      Commit.new(draft: draft, created: existing.nil?)
    end
  end
end
