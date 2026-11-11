module Api
  module V1
    class MiaActionDraftsController < BaseController
      before_action :authenticate_user!
      before_action :require_writable_household!
      before_action :set_draft

      # The participant's own edit of one row; the reader is not involved.
      def setup_card
        current_household.with_lock do
          @draft.reload
          state = @draft.metadata.to_h["setup_card"]
          raise ArgumentError, "That setup card is no longer open." unless state && @draft.pending?

          card = HouseholdFinance::MiaSetupCard.new(current_household, state: state)
          if params[:action_name].to_s.in?(%w[skip unskip])
            update_setup_skip!(params.require(:field).to_s, params[:action_name].to_s)
          else
            card.edit_row(field: params.require(:field), action: params.require(:action_name), part_id: params[:part_id], value: params[:value], label: params[:label])
            current_household.update!(setup_skipped_fields: Array(current_household.setup_skipped_fields) - [ params[:field].to_s ]) if params[:action_name].to_s == "set"
          end
          HouseholdFinance::MiaSetupCardDraft.new(current_household, user: current_user, card: card).sync!(@draft)
          advance_setup_question(card)
        end
        render json: { mia_action_draft: serialize_action_draft(@draft.reload), workspace: workspace_payload_for(@draft.year) }
      rescue ArgumentError => error
        render json: { errors: [ error.message ] }, status: :unprocessable_entity
      end

      def apply
        idempotency_key = request.headers["Idempotency-Key"].to_s.strip
        if idempotency_key.blank? && @draft.draft_type == "action_plan"
          return render json: { errors: [ "Idempotency-Key header is required" ] }, status: :unprocessable_entity
        end
        idempotency_key = "legacy-mia-action:#{@draft.id}:#{current_user.id}" if idempotency_key.blank?
        if (card_state = @draft.metadata.to_h["setup_card"])
          if params[:setup_card_revision].present? && params[:setup_card_revision].to_i != card_state["revision"].to_i
            return render json: { errors: [ "Your card changed. Check it and tap Apply again. Nothing was saved." ], code: "stale_review" }, status: :conflict
          end
          if @draft.mia_action_items.empty?
            return render json: { errors: [ "Nothing on this card is ready to save yet. Add an amount first." ] }, status: :unprocessable_entity
          end
        end
        result = HouseholdFinance::MiaActionDraftApplier.new(@draft, user: current_user, cohort_membership: current_cohort_membership).call(
          idempotency_key: idempotency_key,
          selected_item_ids: params[:item_ids]
        )
        unless result.success?
          body = { errors: result.errors }
          body[:code] = "stale_review" if result.stale?
          return render json: body, status: result.conflict? ? :conflict : :unprocessable_entity
        end

        narrate_applied(result.draft) unless result.replayed?

        render json: {
          mia_action_draft: serialize_action_draft(result.draft),
          mia_action_draft_application: result.application&.slice(:id, :idempotency_key, :selected_item_ids, :status, :completed_at),
          workspace: workspace_payload_for(result.draft.year)
        }
      end

      def cancel
        idempotency_key = request.headers["Idempotency-Key"].to_s.strip
        if idempotency_key.blank? && @draft.draft_type == "action_plan"
          return render json: { errors: [ "Idempotency-Key header is required" ] }, status: :unprocessable_entity
        end
        result = HouseholdFinance::MiaActionDraftCanceler.new(@draft, user: current_user, cohort_membership: current_cohort_membership).call(idempotency_key: idempotency_key)
        unless result.success?
          return render json: { errors: result.errors }, status: result.conflict? ? :conflict : :unprocessable_entity
        end

        unless result.replayed?
          status_message = canceled_message(result.draft)
          append_chat_status_message(status_message)
          update_conversation_action_status("canceled", status_message)
        end

        render json: {
          mia_action_draft: serialize_action_draft(result.draft),
          mia_action_draft_application: result.application&.slice(:id, :idempotency_key, :request_kind, :selected_item_ids, :status, :completed_at),
          workspace: workspace_payload_for(result.draft.year)
        }
      end

      private

      def set_draft
        @draft = current_household.mia_action_drafts.includes(:mia_action_items).find(params[:id])
        ::Mia::ActionDraftScope.authorize!(@draft, user: current_user, membership: current_cohort_membership, runtime: current_participant_runtime)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Mia action draft not found" ] }, status: :not_found
      rescue ::Mia::ActionDraftScope::Mismatch => error
        render json: { errors: [ error.message ] }, status: :conflict
      end

      def append_chat_status_message(content)
        CohortExperience::AssistantMessageWriter.new(
          session: current_chat_session,
          persona: current_persona,
          participant_runtime: current_participant_runtime
        ).create!(content: content)
      rescue StandardError => e
        Rails.logger.warn("Mia action draft status message was not saved draft_id=#{@draft&.id}: #{e.class}: #{e.message}")
        false
      end

      def update_conversation_action_status(status, content)
        HouseholdFinance::MiaConversationReviewStatusUpdater.new(
          current_chat_session,
          reference_key: "mia_action_draft_id",
          reference_id: @draft.id,
          status: status,
          summary: content
        ).call
      rescue StandardError => e
        Rails.logger.warn("Mia conversation action status was not updated draft_id=#{@draft&.id}: #{e.class}: #{e.message}")
        false
      end

      def carry_unresolved_setup(draft)
        return unless draft.draft_type == "household_setup"
        source = draft.source_chat_message || current_chat_session.chat_messages.where(role: "user").order(:id).last
        HouseholdFinance::MiaSetupCardDraft.carry_unresolved!(draft, user: current_user, source_message: source)
      rescue StandardError => e
        Rails.logger.warn("Setup card rows were not carried draft_id=#{draft&.id}: #{e.class}: #{e.message}")
        nil
      end

      # A row she just filled in is no longer the question waiting for an answer.
      # A savepoint keeps a database error here from aborting the row edit's transaction.
      def advance_setup_question(card)
        ActiveRecord::Base.transaction(requires_new: true) do
          session = current_chat_session
          asked = HouseholdFinance::MiaSetupCardTurn.active_field(session)
          next unless asked
          household = current_household.reload
          # She answered Mia's question on the card herself. That question is
          # done, and the next unlabelled number can't land on the row she set.
          if params[:field].to_s == asked && params[:action_name].to_s == "set"
            next session.update!(active_topic: session.active_topic.to_h.merge("setup_card_field" => nil, "setup_card_work_out" => nil, "setup_card_superseded" => asked))
          end
          next if HouseholdFinance::SetupStatus.new(household).missing_field_keys.include?(asked) && !card.field_known?(asked) && !household.setup_skipped_fields.to_a.include?(asked)

          session.update!(active_topic: session.active_topic.to_h.merge("setup_card_field" => HouseholdFinance::MiaSetupCardTurn.next_open_field(household, card)))
        end
      rescue StandardError => e
        Rails.logger.warn("Setup question was not advanced draft_id=#{@draft&.id}: #{e.class}: #{e.message}")
      end

      def carried_setup_card(carried) = carried && HouseholdFinance::MiaSetupCard.new(carried.household, state: carried.metadata["setup_card"])

      def remember_setup_question(draft, carried)
        return unless draft.draft_type == "household_setup" || draft.metadata.to_h["setup_progress"]
        field = carried_setup_card(carried)&.unresolved_field_keys&.first || HouseholdFinance::MiaSetupGuide.new(draft.household.reload).next_missing_field
        session = current_chat_session
        session.update!(active_topic: session.active_topic.to_h.merge("setup_card_field" => field))
      rescue StandardError => e
        Rails.logger.warn("Setup question was not remembered draft_id=#{draft&.id}: #{e.class}: #{e.message}")
      end

      def current_chat_session
        ::Mia::ChatSessionScope.new(household: current_household, user: current_user,
          membership: current_cohort_membership, runtime: current_participant_runtime).find_or_create!
      end

      def workspace_payload_for(year)
        response_year = HouseholdFinance::AnnualBudgetManager.supported_year?(year) ? year : Date.current.year
        annual_plan = HouseholdFinance::AnnualBudgetManager.new(current_household, year: response_year).plan_data
        current_data_presenter(household: current_household.reload, annual_plan: annual_plan).app_data
      end

      # The changes are already saved when this runs, so a failure here must
      # never turn a successful Apply into a 500: fall back to a plain "Done."
      def narrate_applied(draft)
        carried = carry_unresolved_setup(draft)
        status_message = applied_message(draft, carried)
        append_chat_status_message(status_message)
        update_conversation_action_status(draft.status, status_message)
        remember_setup_question(draft, carried)
      rescue StandardError => e
        Rails.logger.error("[MiaActionDrafts] Apply narration failed after commit for draft #{draft.id}: #{e.class}: #{e.message}")
        Sentry.capture_exception(e, tags: { mia_action_draft_id: draft.id }) if defined?(Sentry) && Sentry.initialized?
        begin
          append_chat_status_message("Done.")
          update_conversation_action_status(draft.status, "Done.")
        rescue StandardError => fallback_error
          Rails.logger.error("[MiaActionDrafts] Apply fallback status failed for draft #{draft.id}: #{fallback_error.class}")
        end
      end

      def applied_message(draft, carried = nil)
        if draft.status == "partially_applied"
          remaining = draft.mia_action_items.count { |item| item.applied_at.blank? }
          return "Applied the selected reviewed changes together. #{remaining} #{'step'.pluralize(remaining)} remain in this plan, and no unselected change was applied."
        end

        case draft.draft_type
        when "budget_edit"
          "Applied the reviewed budget edit: #{applied_summary(draft.summary)} The official annual budget is updated, and actual spending stayed unchanged."
        when "income_schedule"
          "Applied the reviewed income change: #{applied_summary(draft.summary)} The income timeline and cash-flow view now use the approved schedule."
        when "household_setup"
          state = draft.metadata.to_h["setup_card"]
          changed = !carried && state && state["change_mode"] && HouseholdFinance::MiaSetupCardReply.applied_sentence(HouseholdFinance::MiaSetupCard.new(draft.household, state: state))
          return changed if changed
          base = "Your household details are saved."
          card = carried_setup_card(carried)
          next_step = if (field = card&.unresolved_field_keys&.first)
            HouseholdFinance::MiaSetupCardReply.question(field, card: card, previous: nil)
          else
            HouseholdFinance::MiaSetupGuide.new(draft.household.reload).after_apply_message
          end
          [ base, setup_card_unresolved_line(card), next_step ].compact.join(" ")
        when "debt_plan"
          "Your reviewed changes are saved. #{HouseholdFinance::MiaSetupGuide.new(draft.household.reload).after_apply_message if draft.metadata['setup_progress']}".strip
        when "action_plan"
          "Your reviewed changes are saved. #{HouseholdFinance::MiaSetupGuide.new(draft.household.reload).after_apply_message unless HouseholdFinance::SetupStatus.new(draft.household).complete?}".strip
        else
          "Your reviewed changes are saved."
        end
      end

      # The rows still waiting on an amount moved to a fresh card.
      def setup_card_unresolved_line(card)
        labels = card&.unresolved_summary.to_a
        "#{labels.to_sentence} #{labels.one? ? 'still needs' : 'still need'} a monthly amount, so #{labels.one? ? "it's" : "they're"} still on your card." if labels.any?
      end

      def update_setup_skip!(field, action)
        raise ArgumentError, "Unknown setup row" unless field.in?(HouseholdFinance::MiaSetupCard::FIELDS)
        skips = Array(current_household.setup_skipped_fields)
        skips = action == "skip" ? skips | [ field ] : skips - [ field ]
        current_household.update!(setup_skipped_fields: skips)
      end

      def applied_summary(summary)
        cleaned = summary.to_s.sub(/\AI drafted\s+/i, "").squish
        cleaned = "the approved change" if cleaned.blank?
        cleaned.sub(/\A\w/) { |first_letter| first_letter.upcase }
      end

      def canceled_message(draft)
        if draft.draft_type == "action_plan"
          applied = draft.mia_action_items.count { |item| item.applied_at.present? }
          canceled = draft.mia_action_items.count { |item| item.canceled_at.present? }
          return "Canceled the remaining #{canceled} #{'step'.pluralize(canceled)} in #{draft.title}. #{applied} previously applied #{'step'.pluralize(applied)} stayed applied."
        end

        unchanged = case draft.draft_type
        when "budget_edit" then "No budget numbers changed."
        when "income_schedule" then "No income timeline changed."
        else "No approved household numbers changed."
        end
        "That review card is canceled. #{unchanged}"
      end

      def serialize_action_draft(draft)
        HouseholdFinance::MiaActionDraftPresenter.new(draft).call
      end
    end
  end
end
