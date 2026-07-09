module Api
  module V1
    class MiaActionDraftsController < BaseController
      before_action :authenticate_user!
      before_action :set_draft

      def apply
        result = HouseholdFinance::MiaActionDraftApplier.new(@draft, user: current_user).call
        unless result.success?
          return render json: { errors: result.errors }, status: :unprocessable_entity
        end

        append_chat_status_message(applied_message(result.draft))

        render json: {
          mia_action_draft: serialize_action_draft(result.draft),
          workspace: workspace_payload_for(result.draft.year)
        }
      end

      def cancel
        result = HouseholdFinance::MiaActionDraftCanceler.new(@draft, user: current_user).call
        unless result.success?
          return render json: { errors: result.errors }, status: :unprocessable_entity
        end

        append_chat_status_message(canceled_message(result.draft))

        render json: {
          mia_action_draft: serialize_action_draft(result.draft),
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
        current_chat_session.chat_messages.create!(role: "assistant", content: content)
      rescue StandardError => e
        Rails.logger.warn("Mia action draft status message was not saved draft_id=#{@draft&.id}: #{e.class}: #{e.message}")
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
        HouseholdFinance::DataPresenter.new(current_household.reload, user: current_user, annual_plan: annual_plan).app_data
      end

      def applied_message(draft)
        "Applied Mia’s budget draft: #{draft.summary} The official annual budget is updated, and actual spending stayed unchanged."
      end

      def canceled_message(draft)
        "Canceled Mia’s budget draft: #{draft.title}. No budget numbers changed."
      end

      def serialize_action_draft(draft)
        HouseholdFinance::MiaActionDraftPresenter.new(draft).call
      end
    end
  end
end
