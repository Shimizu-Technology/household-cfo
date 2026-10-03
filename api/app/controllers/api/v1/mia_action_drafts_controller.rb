module Api
  module V1
    class MiaActionDraftsController < BaseController
      before_action :authenticate_user!
      before_action :require_writable_household!
      before_action :set_draft

      def apply
        idempotency_key = request.headers["Idempotency-Key"].to_s.strip
        if idempotency_key.blank? && @draft.draft_type == "action_plan"
          return render json: { errors: [ "Idempotency-Key header is required" ] }, status: :unprocessable_entity
        end
        idempotency_key = "legacy-mia-action:#{@draft.id}:#{current_user.id}" if idempotency_key.blank?
        result = HouseholdFinance::MiaActionDraftApplier.new(@draft, user: current_user).call(
          idempotency_key: idempotency_key,
          selected_item_ids: params[:item_ids]
        )
        unless result.success?
          return render json: { errors: result.errors }, status: result.conflict? ? :conflict : :unprocessable_entity
        end

        unless result.replayed?
          status_message = applied_message(result.draft)
          append_chat_status_message(status_message)
          update_conversation_action_status(result.draft.status, status_message)
        end

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
        result = HouseholdFinance::MiaActionDraftCanceler.new(@draft, user: current_user).call(idempotency_key: idempotency_key)
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
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Mia action draft not found" ] }, status: :not_found
      end

      def append_chat_status_message(content)
        ::Mia::AssistantMessageWriter.new(
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

      def current_chat_session
        current_household.chat_sessions.find_by(user: current_user) ||
          current_household.chat_sessions.create!(user: current_user, title: "Ask Mia")
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
        current_household.chat_sessions.find_by!(user: current_user)
      end

      def workspace_payload_for(year)
        response_year = HouseholdFinance::AnnualBudgetManager.supported_year?(year) ? year : Date.current.year
        annual_plan = HouseholdFinance::AnnualBudgetManager.new(current_household, year: response_year).plan_data
        current_data_presenter(household: current_household.reload, annual_plan: annual_plan).app_data
      end

      def applied_message(draft)
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
          base = "Applied the reviewed household update: #{applied_summary(draft.summary)} The assistant and Home snapshot now use the approved values."
          "#{base} #{HouseholdFinance::MiaSetupGuide.new(draft.household.reload).after_apply_message}"
        when "action_plan"
          "Applied all reviewed steps in the household action plan. Every step was rechecked against current approved data before the plan committed."
        else
          "Applied the reviewed household update: #{applied_summary(draft.summary)} The assistant and Home snapshot now use the approved values."
        end
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
        "Canceled the assistant review draft: #{draft.title}. #{unchanged}"
      end

      def serialize_action_draft(draft)
        HouseholdFinance::MiaActionDraftPresenter.new(draft).call
      end
    end
  end
end
