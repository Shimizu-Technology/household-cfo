module Api
  module V1
    class MiaMessagesController < BaseController
      before_action :authenticate_user!

      def index
        render json: HouseholdFinance::DataPresenter.new(current_household, user: current_user).mia
      end

      def create
        content = params[:message].to_s.strip
        attached_imports = attached_document_imports
        content = "Please review this upload." if content.blank? && attached_imports.any?
        return render json: { errors: [ "Message can't be blank" ] }, status: :unprocessable_entity if content.blank?
        return render json: { errors: [ "Message is too long (maximum is #{ChatMessage::MAX_CONTENT_LENGTH} characters)" ] }, status: :unprocessable_entity if content.length > ChatMessage::MAX_CONTENT_LENGTH

        session = current_chat_session
        history = session.chat_messages.order(:created_at).last(12).map { |message| { role: message.role, content: message.content } }
        return render_attached_document_response(session, content, attached_imports) if attached_imports.any?

        conversation_context = HouseholdFinance::ConversationContextBuilder.new(session).call
        followup = HouseholdFinance::ConversationFollowupResolver.new(content, conversation_context: conversation_context).call
        routed_content = followup.message
        annual_budget_manager = HouseholdFinance::AnnualBudgetManager.new(current_household, year: budget_year_param)
        pending_draft_answer = pending_guardrail_answer(routed_content)
        action_result = pending_draft_answer ? nil : HouseholdFinance::MiaActionDraftBuilder.new(
          current_household,
          routed_content,
          user: current_user,
          annual_budget_manager: annual_budget_manager,
          selected_month: budget_month_param,
          raw_input: content
        ).call
        coach_answerer = HouseholdFinance::MiaCoachAnswerer.new(
          current_household,
          routed_content,
          annual_budget_manager: annual_budget_manager,
          reference_month: budget_month_param
        )
        coach_answer = (pending_draft_answer || action_result) ? nil : followup.direct_answer || coach_answerer.call
        transaction_lookup_answer = (coach_answer || pending_draft_answer || action_result) ? nil : HouseholdFinance::TransactionLookupAnswerer.new(current_household, routed_content).call
        pending_draft_answer ||= (transaction_lookup_answer || coach_answer || action_result) ? nil : HouseholdFinance::PendingDraftAnswerer.new(current_household, routed_content).call
        spending_report = (pending_draft_answer || transaction_lookup_answer || coach_answer || action_result) ? nil : spending_report_for(routed_content)
        annual_plan = action_result&.annual_plan || (coach_answer ? coach_answerer.prepared_annual_plan : nil)
        budget_answer = nil
        transaction_draft = nil
        unless action_result || coach_answer || transaction_lookup_answer || pending_draft_answer || spending_report
          budget_answer_manager = budget_answer_manager_for(routed_content, annual_budget_manager)
          annual_plan = budget_answer_manager.plan_data
          budget_answer = HouseholdFinance::BudgetQuestionAnswerer.new(routed_content, annual_plan: annual_plan).call
        end
        unless action_result || coach_answer || transaction_lookup_answer || pending_draft_answer || spending_report || budget_answer
          transaction_draft = HouseholdFinance::TransactionDraftBuilder.new(
            current_household,
            routed_content,
            annual_budget_manager: annual_budget_manager,
            plan_prepared: annual_plan.present?,
            raw_input: content
          ).call
          annual_plan = annual_plan_for_transaction_draft(transaction_draft, annual_budget_manager) if transaction_draft
        end
        unless action_result || coach_answer || transaction_lookup_answer || pending_draft_answer || spending_report || budget_answer || transaction_draft
          annual_plan ||= annual_budget_manager.plan_data
        end
        assistant_content = assistant_content_for(content, history, annual_plan, spending_report, transaction_draft, budget_answer, transaction_lookup_answer, pending_draft_answer, coach_answer, action_result, conversation_context)
        user_message, assistant_message = persist_chat_messages(session, content, attached_imports, assistant_content)
        mia_action_draft = persist_mia_action_draft(action_result, user_message, assistant_message)
        if action_result&.proposal && mia_action_draft.nil?
          assistant_message.update!(content: action_draft_persistence_failure_message)
          assistant_message.reload
        end
        annual_plan = HouseholdFinance::AnnualBudgetManager.new(current_household, year: mia_action_draft.year).plan_data if mia_action_draft

        compact_conversation(session, user_message, assistant_message, follow_up: followup.follow_up?)

        render json: {
          user_message: serialize_chat_message(user_message, author: "You"),
          assistant_message: serialize_chat_message(assistant_message, author: "Mia"),
          transaction_draft: transaction_draft ? serialize_transaction_draft(transaction_draft) : nil,
          mia_action_draft: mia_action_draft ? serialize_mia_action_draft(mia_action_draft) : nil,
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

      def render_attached_document_response(session, content, attached_imports)
        processed_imports = process_attached_imports(attached_imports)
        assistant_content = attached_document_message(content, processed_imports)
        annual_plan = HouseholdFinance::AnnualBudgetManager.new(current_household, year: budget_year_param).plan_data
        user_message, assistant_message = ApplicationRecord.transaction do
          [
            session.chat_messages.create!(role: "user", content: content, attachments: processed_imports.map { |document_import| serialize_attachment(document_import) }),
            session.chat_messages.create!(role: "assistant", content: assistant_content)
          ]
        end
        compact_conversation(session, user_message, assistant_message)

        render json: {
          user_message: serialize_chat_message(user_message, author: "You"),
          assistant_message: serialize_chat_message(assistant_message, author: "Mia"),
          transaction_draft: nil,
          mia_action_draft: nil,
          budget: HouseholdFinance::DataPresenter.new(current_household.reload, user: current_user, annual_plan: annual_plan).budget,
          spending_report: nil
        }, status: :created
      end

      def attached_document_imports
        ids = Array(params[:document_import_ids]).filter_map { |id| id.to_i if id.to_i.positive? }.uniq.first(5)
        return [] if ids.empty?

        current_household.financial_document_imports.where(id: ids).order(:id).to_a
      end

      def process_attached_imports(document_imports)
        document_imports.each do |document_import|
          FinancialDocumentExtractionJob.perform_later(document_import.id) if document_import.status == "uploaded"
        end
        document_imports.map(&:reload)
      end

      def persist_chat_messages(session, content, attached_imports, assistant_content)
        ApplicationRecord.transaction do
          [
            session.chat_messages.create!(role: "user", content: content, attachments: attached_imports.map { |document_import| serialize_attachment(document_import) }),
            session.chat_messages.create!(role: "assistant", content: assistant_content)
          ]
        end
      end

      def persist_mia_action_draft(action_result, user_message, assistant_message)
        return unless action_result&.proposal

        action_result.proposal.create_draft!(source_chat_message: user_message, assistant_chat_message: assistant_message)
      rescue ActiveRecord::ActiveRecordError => e
        Rails.logger.warn("Mia action draft could not be persisted chat_message_id=#{assistant_message&.id}: #{e.class}: #{e.message}")
        nil
      end

      def action_draft_persistence_failure_message
        "I understood the budget edit, but I could not prepare the review card. Nothing changed in the official budget. Please try again or edit the annual budget directly."
      end

      def serialize_chat_message(message, author: nil)
        payload = message.as_api_json(author: author)
        imports_by_id = attachment_imports_by_id(payload[:attachments])
        payload[:attachments] = Array(payload[:attachments]).map { |attachment| serialize_chat_attachment(attachment, imports_by_id: imports_by_id) }
        payload
      end

      def attachment_imports_by_id(attachments)
        ids = Array(attachments).filter_map { |attachment| attachment["document_import_id"] || attachment[:document_import_id] }.map(&:to_i).select(&:positive?).uniq
        return {} if ids.empty?

        current_household.financial_document_imports.where(id: ids).index_by(&:id)
      end

      def serialize_chat_attachment(attachment, imports_by_id:)
        payload = attachment.respond_to?(:deep_symbolize_keys) ? attachment.deep_symbolize_keys : {}
        document_import = imports_by_id[payload[:document_import_id].to_i]
        return payload unless document_import

        payload.merge(
          filename: document_import.filename,
          content_type: document_import.content_type,
          document_kind: document_import.document_kind,
          status: document_import.status,
          source_available: document_import.source_available?,
          preview_url: chat_attachment_preview_url(document_import)
        ).compact
      end

      def chat_attachment_preview_url(document_import)
        return unless S3Service.configured?
        return unless document_import.source_available?
        return unless document_import.content_type.in?(%w[image/jpeg image/png image/webp])

        S3Service.presigned_url(document_import.s3_key, expires_in: 300, filename: document_import.filename, disposition: :inline)
      rescue S3Service::MissingConfigurationError
        nil
      end

      def serialize_attachment(document_import)
        {
          document_import_id: document_import.id,
          filename: document_import.filename,
          content_type: document_import.content_type,
          document_kind: document_import.document_kind,
          status: document_import.status,
          source_available: document_import.source_available?
        }
      end

      def attached_document_message(_content, attached_imports)
        attached_imports.map { |document_import| attached_document_result_message(document_import) }.join("\n\n")
      end

      def attached_document_result_message(document_import)
        if document_import.status == "failed"
          return "I could not read the #{evidence_label(document_import)} yet: #{document_import.extraction_error.presence || 'extraction failed'}. The upload is saved, but no household numbers changed."
        end

        drafts = document_import.transaction_drafts.pending.includes(:budget_category, :transaction_draft_splits).order(:occurred_on, :id).to_a
        if drafts.any?
          return drafted_document_transaction_message(document_import, drafts)
        end

        items = document_import.items.where(ignored: false).order(:id).to_a
        if items.any?
          labels = items.first(3).map(&:label).to_sentence
          return "Good — I found #{items.length} budget/profile setup value#{'s' unless items.length == 1} for review: #{labels}. You stay the CFO here: open Review imports to approve or adjust them before anything updates the household plan."
        end

        if document_import.status.in?(%w[uploaded processing])
          return "The #{evidence_label(document_import)} is still processing. I’ll show review cards here as soon as the backend finishes reading it."
        end

        "I read the #{evidence_label(document_import)}, but I did not find clear money details to draft. The upload is saved for review, and no household numbers changed."
      end

      def drafted_document_transaction_message(document_import, drafts)
        first_draft = drafts.first
        amount = money(first_draft.total_amount_cents)
        date = first_draft.occurred_on.strftime("%b %-d, %Y")
        merchant = first_draft.merchant.presence || evidence_label(document_import).titleize
        category = first_draft.budget_category&.name || first_draft.transaction_draft_splits.first&.category_name || "Uncategorized"
        intro = "Good — I found #{merchant} for #{amount} on #{date} and drafted it in #{category}."
        extra = drafts.length > 1 ? " I also found #{drafts.length - 1} more transaction row#{'s' unless drafts.length == 2}." : ""
        "#{intro}#{extra} You stay the CFO here: review the card#{'s' if drafts.length > 1} below before anything touches actuals."
      end

      def evidence_label(document_import)
        return "receipt screenshot" if document_import.document_kind == "receipt" && document_import.content_type.to_s.start_with?("image/")
        return "statement screenshot" if document_import.document_kind == "statement" && document_import.content_type.to_s.start_with?("image/")
        return "pay stub image" if document_import.document_kind == "pay_stub" && document_import.content_type.to_s.start_with?("image/")

        document_import.document_kind.to_s.humanize.downcase
      end

      def pending_guardrail_answer(content)
        return unless HouseholdFinance::PendingDraftAnswerer.guardrail_question?(content)

        HouseholdFinance::PendingDraftAnswerer.new(current_household, content).call
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

      def assistant_content_for(content, history, annual_plan, spending_report, transaction_draft, budget_answer, transaction_lookup_answer, pending_draft_answer, coach_answer, action_result, conversation_context)
        if action_result
          return action_result.response
        end
        if coach_answer
          return narrate_structured_answer(content, history, conversation_context, kind: "coaching", fallback_response: coach_answer, annual_plan: annual_plan, write_state: "no_write")
        end
        if transaction_lookup_answer
          return narrate_structured_answer(content, history, conversation_context, kind: "transaction_lookup", fallback_response: transaction_lookup_answer, write_state: "no_write")
        end
        if pending_draft_answer
          return narrate_structured_answer(content, history, conversation_context, kind: "pending_drafts", fallback_response: pending_draft_answer, write_state: "pending_review")
        end
        if budget_answer
          return narrate_structured_answer(content, history, conversation_context, kind: "budget_question", fallback_response: budget_answer, annual_plan: annual_plan, write_state: "no_write")
        end
        if spending_report
          report_answer = HouseholdFinance::SpendingReportNarrator.new(spending_report, prompt: content).call
          return narrate_structured_answer(content, history, conversation_context, kind: "spending_report", fallback_response: report_answer, spending_report: spending_report, write_state: "no_write")
        end
        if transaction_draft
          draft_answer = drafted_transaction_message(transaction_draft)
          return narrate_structured_answer(content, history, conversation_context, kind: "transaction_draft", fallback_response: draft_answer, annual_plan: annual_plan, transaction_draft: transaction_draft, write_state: "pending_review")
        end

        context = HouseholdFinance::MiaContextBuilder.new(
          current_household,
          annual_plan: annual_plan,
          reference_month: budget_month_param,
          conversation_context: conversation_context
        ).call
        ::Demo::MiaResponder.new.call(content, history: history, context: context, draft_capable: false)
      end

      def narrate_structured_answer(content, history, conversation_context, kind:, fallback_response:, write_state:, annual_plan: nil, spending_report: nil, transaction_draft: nil)
        answer_packet = HouseholdFinance::MiaAnswerPacketBuilder.new(
          kind: kind,
          fallback_response: fallback_response,
          write_state: write_state,
          selected_month: budget_month_param,
          annual_plan: annual_plan,
          spending_report: spending_report,
          transaction_draft: transaction_draft,
          conversation_context: conversation_context
        ).call

        HouseholdFinance::MiaNarrator.new(
          user_message: content,
          history: history,
          answer_packet: answer_packet
        ).call
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

      def serialize_mia_action_draft(draft)
        HouseholdFinance::MiaActionDraftPresenter.new(draft).call
      end

      def serialize_transaction_draft(draft)
        {
          id: draft.id,
          occurred_on: draft.occurred_on.iso8601,
          merchant: draft.merchant,
          amount: HouseholdFinance::Money.dollars(draft.total_amount_cents),
          amount_cents: draft.total_amount_cents,
          status: draft.status,
          source_type: draft.source_type,
          financial_document_import_id: draft.financial_document_import_id,
          category_id: draft.budget_category_id,
          category_name: draft.budget_category&.name,
          stack_label: draft.budget_category&.stack_label,
          splits: draft.transaction_draft_splits.ordered.includes(:budget_category).map do |split|
            {
              id: split.id,
              budget_category_id: split.budget_category_id,
              category_name: split.budget_category&.name || split.category_name,
              stack_key: split.budget_category&.stack_key || split.stack_key,
              stack_label: split.budget_category&.stack_label || split.stack_key.to_s.humanize,
              amount: HouseholdFinance::Money.dollars(split.amount_cents),
              amount_cents: split.amount_cents,
              notes: split.notes,
              confidence: split.confidence
            }
          end,
          matches: [],
          matched_transaction_id: draft.matched_transaction_id,
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
      rescue StandardError => e
        Rails.logger.warn("Conversation compaction could not be scheduled chat_session_id=#{session&.id}: #{e.class}: #{e.message}")
        false
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
