module Api
  module V1
    class MiaMessagesController < BaseController
      before_action :authenticate_user!

      def index
        render json: HouseholdFinance::DataPresenter.new(current_household, user: current_user).mia
      end

      def create
        content = params.require(:message).to_s.strip
        return render json: { errors: [ "Message can't be blank" ] }, status: :unprocessable_entity if content.blank?
        return render json: { errors: [ "Message is too long (maximum is #{ChatMessage::MAX_CONTENT_LENGTH} characters)" ] }, status: :unprocessable_entity if content.length > ChatMessage::MAX_CONTENT_LENGTH

        session = current_chat_session
        history = session.chat_messages.order(:created_at).last(12).map { |message| { role: message.role, content: message.content } }
        conversation_context = HouseholdFinance::ConversationContextBuilder.new(session).call
        followup = HouseholdFinance::ConversationFollowupResolver.new(content, conversation_context: conversation_context).call
        routed_content = followup.message
        annual_budget_manager = HouseholdFinance::AnnualBudgetManager.new(current_household, year: budget_year_param)
        coach_answerer = HouseholdFinance::MiaCoachAnswerer.new(
          current_household,
          routed_content,
          annual_budget_manager: annual_budget_manager,
          reference_month: budget_month_param
        )
        coach_answer = followup.direct_answer || coach_answerer.call
        transaction_lookup_answer = coach_answer ? nil : HouseholdFinance::TransactionLookupAnswerer.new(current_household, routed_content).call
        pending_draft_answer = (transaction_lookup_answer || coach_answer) ? nil : HouseholdFinance::PendingDraftAnswerer.new(current_household, routed_content).call
        spending_report = (pending_draft_answer || transaction_lookup_answer || coach_answer) ? nil : spending_report_for(routed_content)
        annual_plan = coach_answer ? coach_answerer.prepared_annual_plan : nil
        budget_answer = nil
        transaction_draft = nil
        unless coach_answer || transaction_lookup_answer || pending_draft_answer || spending_report
          budget_answer_manager = budget_answer_manager_for(routed_content, annual_budget_manager)
          annual_plan = budget_answer_manager.plan_data
          budget_answer = HouseholdFinance::BudgetQuestionAnswerer.new(routed_content, annual_plan: annual_plan).call
        end
        unless coach_answer || transaction_lookup_answer || pending_draft_answer || spending_report || budget_answer
          transaction_draft = HouseholdFinance::TransactionDraftBuilder.new(
            current_household,
            content,
            annual_budget_manager: annual_budget_manager,
            plan_prepared: annual_plan.present?
          ).call
          annual_plan = annual_plan_for_transaction_draft(transaction_draft, annual_budget_manager) if transaction_draft
        end
        unless coach_answer || transaction_lookup_answer || pending_draft_answer || spending_report || budget_answer || transaction_draft
          annual_plan ||= annual_budget_manager.plan_data
        end
        assistant_content = assistant_content_for(content, history, annual_plan, spending_report, transaction_draft, budget_answer, transaction_lookup_answer, pending_draft_answer, coach_answer, conversation_context)
        user_message, assistant_message = ApplicationRecord.transaction do
          [
            session.chat_messages.create!(role: "user", content: content),
            session.chat_messages.create!(role: "assistant", content: assistant_content)
          ]
        end

        compact_conversation(session, user_message, assistant_message, follow_up: followup.follow_up?)

        render json: {
          user_message: user_message.as_api_json(author: "You"),
          assistant_message: assistant_message.as_api_json(author: "Mia"),
          transaction_draft: transaction_draft ? serialize_transaction_draft(transaction_draft) : nil,
          budget: annual_plan ? HouseholdFinance::DataPresenter.new(current_household.reload, user: current_user, annual_plan: annual_plan).budget : nil,
          spending_report: spending_report
        }, status: :created
      end

      def destroy
        if (session = current_household.chat_sessions.find_by(user: current_user))
          session.chat_messages.delete_all
          session.update!(rolling_summary: nil, open_topics: [], active_topic: {}, last_compacted_message_id: nil, last_compacted_at: nil)
        end
        head :no_content
      end

      private

      def budget_year_param
        return Date.current.year if params[:year].blank?

        params[:year].to_i.clamp(2000, 2100)
      end

      def budget_month_param
        return Date.current.month if params[:month].blank?

        params[:month].to_i.clamp(1, 12)
      end

      def spending_report_for(content)
        range = HouseholdFinance::SpendingReportQuery.new(content).range
        return unless range

        HouseholdFinance::SpendingReport.new(current_household, start_on: range.fetch(:start_on), end_on: range.fetch(:end_on)).as_json
      rescue ArgumentError
        nil
      end

      def annual_plan_for_transaction_draft(transaction_draft, annual_budget_manager)
        return annual_budget_manager.plan_data if annual_budget_manager.year == transaction_draft.occurred_on.year

        HouseholdFinance::AnnualBudgetManager.new(current_household, year: transaction_draft.occurred_on.year).plan_data
      end

      def budget_answer_manager_for(content, fallback_manager)
        return fallback_manager unless HouseholdFinance::BudgetQuestionAnswerer.budget_question?(content)

        target_year = HouseholdFinance::BudgetQuestionAnswerer.relative_budget_year(content)
        return fallback_manager unless target_year && HouseholdFinance::AnnualBudgetManager.supported_year?(target_year)
        return fallback_manager if target_year == fallback_manager.year

        HouseholdFinance::AnnualBudgetManager.new(current_household, year: target_year)
      end

      def assistant_content_for(content, history, annual_plan, spending_report, transaction_draft, budget_answer, transaction_lookup_answer, pending_draft_answer, coach_answer, conversation_context)
        return coach_answer if coach_answer
        return transaction_lookup_answer if transaction_lookup_answer
        return pending_draft_answer if pending_draft_answer
        return budget_answer if budget_answer
        return HouseholdFinance::SpendingReportNarrator.new(spending_report, prompt: content).call if spending_report
        return drafted_transaction_message(transaction_draft) if transaction_draft

        context = HouseholdFinance::MiaContextBuilder.new(
          current_household,
          annual_plan: annual_plan,
          reference_month: budget_month_param,
          conversation_context: conversation_context
        ).call
        ::Demo::MiaResponder.new.call(content, history: history, context: context, draft_capable: false)
      end

      def drafted_transaction_message(draft)
        category = draft.budget_category&.name || "Uncategorized"
        "I drafted this for review: #{draft.merchant} for #{money(draft.total_amount_cents)} in #{category}. Confirm it only if the merchant, amount, and category are right. Month-to-date actuals will not change until you approve it."
      end

      def money(cents)
        ActionController::Base.helpers.number_to_currency(
          HouseholdFinance::Money.dollars(cents),
          precision: cents.to_i % 100 == 0 ? 0 : 2
        )
      end

      def serialize_transaction_draft(draft)
        {
          id: draft.id,
          occurred_on: draft.occurred_on.iso8601,
          merchant: draft.merchant,
          amount: HouseholdFinance::Money.dollars(draft.total_amount_cents),
          status: draft.status,
          source_type: draft.source_type,
          category_id: draft.budget_category_id,
          category_name: draft.budget_category&.name,
          stack_label: draft.budget_category&.stack_label,
          summary: "#{draft.merchant} — #{ActionController::Base.helpers.number_to_currency(HouseholdFinance::Money.dollars(draft.total_amount_cents), precision: 2)}"
        }
      end

      def compact_conversation(session, user_message, assistant_message, follow_up: false)
        HouseholdFinance::ConversationCompactor.new(
          session,
          user_message: user_message,
          assistant_message: assistant_message,
          follow_up: follow_up
        ).call
      end

      def current_chat_session
        current_household.chat_sessions.find_by(user: current_user) ||
          current_household.chat_sessions.create!(user: current_user, title: "Ask Mia")
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
        current_household.chat_sessions.find_by!(user: current_user)
      end
    end
  end
end
