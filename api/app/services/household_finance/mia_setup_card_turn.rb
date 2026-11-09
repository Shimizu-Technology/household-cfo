module HouseholdFinance
  # One participant message against the setup card. Nothing is written until
  # commit!, which runs alongside the chat messages so they save together.
  class MiaSetupCardTurn
    OFF_REPLY = "I can't read setup answers just now, and nothing was saved. Please try again in a moment, or tap Enter my numbers to keep going.".freeze
    KEEP_GOING = "Take your time.".freeze
    TITLE = "Your setup so far".freeze
    Plan = Data.define(:reply, :update_text, :continues, :next_field)
    Commit = Data.define(:draft, :created)

    class << self
      def card_draft(household, user:, session:)
        household.mia_action_drafts.pending.where(draft_type: "household_setup", requested_by_user: user)
          .where("mia_action_drafts.metadata ? 'setup_card'").joins(:source_chat_message)
          .where(chat_messages: { chat_session_id: session.id }).recent_first.first
      end

      def open?(household, user:, session:)
        SetupStatus.new(household).missing_field_keys.any? || card_draft(household, user: user, session: session).present?
      end

      def active_field(session) = session.active_topic.to_h["setup_card_field"].presence_in(MiaSetupCard::FIELDS)

      def reader_context(household, user:, session:)
        card = load_card(household, user: user, session: session)
        { saved: saved_values(household), draft: draft_rows(card), skipped: Array(household.setup_skipped_fields), last_asked: active_field(session).to_s }
      end

      def load_card(household, user:, session:)
        draft = card_draft(household, user: user, session: session)
        return MiaSetupCard.new(household, state: draft.metadata["setup_card"]) if draft
        card = MiaSetupCard.new(household)
        previous = household.mia_action_drafts.where(draft_type: "household_setup", status: "applied", requested_by_user: user)
          .where("mia_action_drafts.metadata ? 'setup_card'").recent_first.first
        card.carry_parts_from(previous.metadata["setup_card"]) if previous
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

    def initialize(household:, user:, session:, reading:, active_topic: session.active_topic.to_h)
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
      @session.update!(active_topic: @session.active_topic.to_h.merge("setup_card_field" => topic_field))
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
      updates = card.apply_changes(changes.except("skips", "help_topic"))
      card.apply_preferences(@reading.spending_preferences)
      @card_touched = updates.any? { |update| !update.action.in?(%i[not_found no_breakdown debt_on_file]) }
      skipped = skip_fields(changes["skips"])
      update_text = [ MiaSetupCardReply.updated_text(updates, card).presence, MiaSetupCardReply.skipped_text(skipped) ].compact.join(" ")
      next_field = next_open_field(skipped)
      if update_text.present?
        return Plan.new(reply: nil, update_text: update_text, continues: true, next_field: next_field) if @reading.question
        return Plan.new(reply: compose(update_text, next_field, asked: asked), update_text: update_text, continues: false, next_field: next_field)
      end
      return help_plan(changes["help_topic"], next_field) if changes["help_topic"]
      return if @reading.question || @reading.facts.any? || !asked
      Plan.new(reply: compose(KEEP_GOING, next_field, asked: asked), update_text: nil, continues: false, next_field: next_field)
    end

    def help_plan(field, next_field)
      question = MiaSetupCardReply.question(field, card: card, previous: nil)
      Plan.new(reply: "#{MiaSetupCardReply.help(field)} #{question}", update_text: nil, continues: false, next_field: next_field || field)
    end

    def compose(lead, next_field, asked:)
      closing = next_field ? MiaSetupCardReply.question(next_field, card: card, previous: asked) : finish_text
      first_save = "Nothing saves until you tap Apply." if @card_touched && !card_draft
      [ lead.presence, first_save, closing ].compact.join(" ")
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

    # A row she just started and left unfinished comes before a new question.
    def next_open_field(new_skips)
      open = (@status.missing_field_keys - Array(@household.setup_skipped_fields) - new_skips).reject { |field| card.field_known?(field) }
      open.find { |field| card.unresolved?(field) || (field == MiaSetupCard::DEBT_FIELD && card.debts_without_minimum.any?) } || open.first
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
