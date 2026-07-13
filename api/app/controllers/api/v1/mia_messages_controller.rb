module Api
  module V1
    class MiaMessagesController < BaseController
      before_action :authenticate_user!

      def index
        render json: HouseholdFinance::DataPresenter.new(current_household, user: current_user).mia(
          before_id: params[:before_id],
          limit: params[:limit]
        )
      end

      def create
        content = params[:message].to_s.strip
        attached_imports = attached_document_imports
        content = "Please review this upload." if content.blank? && attached_imports.any?
        return render json: { errors: [ "Message can't be blank" ] }, status: :unprocessable_entity if content.blank?
        return render json: { errors: [ "Message is too long (maximum is #{ChatMessage::MAX_CONTENT_LENGTH} characters)" ] }, status: :unprocessable_entity if content.length > ChatMessage::MAX_CONTENT_LENGTH

        session = current_chat_session
        transcript = HouseholdFinance::ConversationTranscriptBuilder.new(session).call
        history = transcript.map { |message| message.slice(:role, :content) }
        return render_attached_document_response(session, content, attached_imports) if attached_imports.any?

        annual_budget_manager = HouseholdFinance::AnnualBudgetManager.new(current_household, year: budget_year_param)
        intent_plan = annual_budget_manager.plan_data
        conversation_context = HouseholdFinance::ConversationContextBuilder.new(session).call
        intent_context = HouseholdFinance::MiaIntentContextBuilder.new(
          current_household,
          annual_plan: intent_plan,
          conversation_context: conversation_context,
          transcript: transcript,
          selected_month: budget_month_param
        ).call
        intent_result = HouseholdFinance::MiaIntentResolver.new(
          user_message: content,
          context: intent_context
        ).call

        if intent_result
          routed = route_model_intent(
            intent_result,
            content: content,
            annual_budget_manager: annual_budget_manager,
            annual_plan: intent_plan
          )
        else
          routed = route_legacy_message(
            content,
            conversation_context: conversation_context,
            annual_budget_manager: annual_budget_manager
          )
        end

        followup = routed.fetch(:followup)
        pending_draft_answer = routed[:pending_draft_answer]
        action_result = routed[:action_result]
        coach_answer = routed[:coach_answer]
        transaction_lookup_answer = routed[:transaction_lookup_answer]
        spending_report = routed[:spending_report]
        annual_plan = routed[:annual_plan]
        budget_answer = routed[:budget_answer]
        transaction_draft = routed[:transaction_draft]
        transaction_draft_answer = routed[:transaction_draft_answer]
        intent_direct_answer = routed[:direct_answer]
        conversation_resolution = resolved_conversation_turn(intent_result)
        response_conversation_context = resolved_conversation_context(conversation_context, conversation_resolution)

        assistant_content = assistant_content_for(
          content,
          history,
          annual_plan,
          spending_report,
          transaction_draft,
          transaction_draft_answer,
          budget_answer,
          transaction_lookup_answer,
          pending_draft_answer,
          coach_answer,
          action_result,
          response_conversation_context,
          direct_answer: intent_direct_answer,
          conversation_resolution: conversation_resolution
        )
        user_message, assistant_message = persist_chat_messages(session, content, attached_imports, assistant_content)
        mia_action_draft = action_result&.existing_draft || persist_mia_action_draft(action_result, user_message, assistant_message)
        if action_result&.proposal && mia_action_draft.nil?
          assistant_message.update!(content: action_draft_persistence_failure_message)
          assistant_message.reload
        end
        annual_plan = HouseholdFinance::AnnualBudgetManager.new(current_household, year: mia_action_draft.year).plan_data if mia_action_draft

        if intent_result
          update_conversation_state(
            session,
            intent_result: intent_result,
            user_message: user_message,
            assistant_message: assistant_message,
            mia_action_draft: mia_action_draft,
            transaction_draft: transaction_draft
          )
        else
          compact_conversation(session, user_message, assistant_message, follow_up: followup.follow_up?)
        end

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
      rescue StandardError => e
        Rails.logger.error("Mia action draft could not be persisted chat_message_id=#{assistant_message&.id}: #{e.class}: #{e.message}")
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
        return attached_document_result_message(attached_imports.first) if attached_imports.one? && attached_imports.first.document_kind != "statement"

        processing = attached_imports.select { |document_import| document_import.status.in?(%w[uploaded processing]) }
        if processing.any?
          completed_count = attached_imports.length - processing.length
          return "I’m still reading all #{attached_imports.length} uploads. #{completed_count} finished and #{processing.length} remain, so I’m not reporting partial findings as complete. The review queue will be prepared after every upload finishes."
        end

        failed = attached_imports.select(&:failed?)
        drafts = attached_imports.flat_map do |document_import|
          document_import.transaction_drafts.pending.includes(:budget_category, :transaction_draft_splits).order(:occurred_on, :id).to_a
        end
        items = attached_imports.flat_map { |document_import| document_import.items.where(ignored: false).order(:id).to_a }
        completion_line = attached_imports.one? ? "Finished reading the statement upload." : "Finished reading all #{attached_imports.length} uploads."
        parts = [ completion_line, attached_documents_route_summary(attached_imports) ]
        if drafts.any?
          dates = drafts.map(&:occurred_on).compact
          date_range = if dates.any?
            " covering #{dates.min.strftime('%b %-d, %Y')} through #{dates.max.strftime('%b %-d, %Y')}"
          else
            ""
          end
          parts << "I created #{drafts.length} pending transaction reviews#{date_range}. Every drafted row is available in the review queue below and in My Profile → Import history; use search and pagination to inspect all of them."
        end
        parts << "I also found #{items.length} budget/profile setup value#{'s' unless items.length == 1} for review in Import history." if items.any?
        if failed.any?
          failure_details = failed.map { |document_import| "#{evidence_label(document_import)}: #{document_import.extraction_error.presence || 'extraction failed'}" }.to_sentence
          parts << "#{failed.length} upload#{'s' unless failed.length == 1} failed, so those files produced no drafts: #{failure_details}."
        end
        if drafts.empty? && items.empty? && failed.empty?
          parts << "I did not find clear money details to draft. No household numbers changed."
        else
          parts << "Everything remains pending until you confirm or match each transaction; actuals have not changed."
        end
        parts.join(" ")
      end

      def attached_documents_route_summary(document_imports)
        conflicts = document_imports.select { |document_import| document_import.metadata.to_h["routing_requires_confirmation"] }
        if conflicts.any?
          descriptions = conflicts.map do |document_import|
            metadata = document_import.metadata.to_h
            comparison = if metadata["routing_conflict_reason"] == "participant_signals"
              "your message described #{metadata['routing_resolved_kind'].to_s.humanize.downcase}, selected type was #{metadata['declared_document_kind'].to_s.humanize.downcase}"
            else
              "you described #{metadata['routing_resolved_kind'].to_s.humanize.downcase}, Mia detected #{metadata['routing_detected_kind'].to_s.humanize.downcase}"
            end
            "#{evidence_label(document_import)} (#{comparison})"
          end
          return "I flagged #{descriptions.to_sentence} for a routing check and preserved your description."
        end

        destinations = document_imports.map { |document_import| document_routing_destination(document_import) }.uniq
        return "I routed the uploads to transaction and household setup review." if destinations.many?
        return "I routed the upload#{'s' if document_imports.many?} to household setup review." if destinations == [ "household_setup_review" ]
        return "I saved the upload#{'s' if document_imports.many?} in private Import history for review." if destinations == [ "private_document_review" ]

        "I routed the upload#{'s' if document_imports.many?} to pending transaction review."
      end

      def attached_document_result_message(document_import)
        if document_import.status == "failed"
          return "I could not read the #{evidence_label(document_import)} yet: #{document_import.extraction_error.presence || 'extraction failed'}. The upload is saved, but no household numbers changed."
        end

        route_line = attached_document_route_line(document_import)
        drafts = document_import.transaction_drafts.pending.includes(:budget_category, :transaction_draft_splits).order(:occurred_on, :id).to_a
        if drafts.any?
          return "#{route_line} #{drafted_document_transaction_message(document_import, drafts)}"
        end

        items = document_import.items.where(ignored: false).order(:id).to_a
        if items.any?
          labels = items.first(3).map(&:label).to_sentence
          return "#{route_line} I found #{items.length} budget/profile setup value#{'s' unless items.length == 1} for review: #{labels}. You stay the CFO here: open Review imports to approve or adjust them before anything updates the household plan."
        end

        if document_import.status.in?(%w[uploaded processing])
          return "#{route_line} The #{evidence_label(document_import)} is still processing. I’ll show review cards here as soon as the app finishes reading it."
        end

        "#{route_line} I read the #{evidence_label(document_import)}, but I did not find clear money details to draft. The upload is saved in Import history, and no household numbers changed."
      end

      def attached_document_route_line(document_import)
        metadata = document_import.metadata.to_h
        resolved_kind = metadata["routing_resolved_kind"].presence || document_import.document_kind || "other"
        if metadata["routing_requires_confirmation"]
          if metadata["routing_conflict_reason"] == "participant_signals"
            selected_kind = metadata["declared_document_kind"].presence || "another document type"
            return "Your message described this as #{resolved_kind.humanize.downcase}, but the selected type was #{selected_kind.humanize.downcase}. I used your message and flagged the routing difference for review."
          end

          detected_kind = metadata["routing_detected_kind"].presence || "another document type"
          return "You described this as #{resolved_kind.humanize.downcase}, but I detected #{detected_kind.humanize.downcase}. I kept your description and flagged the routing difference for review."
        end

        destination = case document_routing_destination(document_import)
        when "transaction_review" then "pending transaction review"
        when "household_setup_review" then "household setup review"
        else "private Import history"
        end
        "I recognized this as #{resolved_kind.humanize.downcase} and routed it to #{destination}."
      end

      def document_routing_destination(document_import)
        document_import.metadata.to_h["routing_destination"].presence ||
          FinancialDocuments::RoutingDecision::DESTINATIONS.fetch(document_import.document_kind, "private_document_review")
      end

      def drafted_document_transaction_message(document_import, drafts)
        first_draft = drafts.first
        amount = money(first_draft.total_amount_cents)
        date = first_draft.occurred_on.strftime("%b %-d, %Y")
        merchant = first_draft.merchant.presence || evidence_label(document_import).titleize
        category = first_draft.budget_category&.name || first_draft.transaction_draft_splits.first&.category_name || "Uncategorized"
        intro = "I found #{merchant} for #{amount} on #{date} and drafted it in #{category}."
        extra = drafts.length > 1 ? " I also found #{drafts.length - 1} more transaction row#{'s' unless drafts.length == 2}." : ""
        "#{intro}#{extra} You stay the CFO here: review the card#{'s' if drafts.length > 1} below before anything touches actuals."
      end

      def evidence_label(document_import)
        return "receipt screenshot" if document_import.document_kind == "receipt" && document_import.content_type.to_s.start_with?("image/")
        return "statement screenshot" if document_import.document_kind == "statement" && document_import.content_type.to_s.start_with?("image/")
        return "pay stub image" if document_import.document_kind == "pay_stub" && document_import.content_type.to_s.start_with?("image/")

        document_import.document_kind.to_s.humanize.downcase
      end

      def route_model_intent(intent_result, content:, annual_budget_manager:, annual_plan:)
        resolved_content = intent_result.resolved_message.presence || content
        direct_answer = intent_result.clarification? ? clarification_answer(intent_result) : nil
        pending_draft_answer = pending_guardrail_answer(content)
        action_result = nil
        coach_answer = nil
        transaction_lookup_answer = nil
        spending_report = nil
        budget_answer = nil
        transaction_draft = nil
        transaction_draft_answer = nil

        unless direct_answer || pending_draft_answer
          case intent_result.intent
          when "budget_action"
            if intent_result.actionable?
              action_result = HouseholdFinance::MiaActionDraftBuilder.new(
                current_household,
                user: current_user,
                annual_budget_manager: annual_budget_manager,
                selected_month: budget_month_param,
                raw_input: content,
                command: intent_result.action
              ).call
            else
              direct_answer = clarification_answer(intent_result)
            end
          when "budget_question"
            budget_manager = budget_answer_manager_for(resolved_content, annual_budget_manager)
            annual_plan = budget_manager.plan_data
            budget_answer = HouseholdFinance::BudgetQuestionAnswerer.new(resolved_content, annual_plan: annual_plan).call
            if budget_answer.blank?
              coach_answerer = HouseholdFinance::MiaCoachAnswerer.new(
                current_household,
                resolved_content,
                annual_budget_manager: budget_manager,
                reference_month: budget_month_param
              )
              coach_answer = coach_answerer.call
              annual_plan = coach_answerer.prepared_annual_plan || annual_plan
            end
          when "spending_report"
            spending_report = spending_report_for(resolved_content)
          when "transaction_report"
            if intent_result.transaction_report_action? && intent_result.actionable?
              creation = HouseholdFinance::MiaTransactionDraftCreator.new(
                current_household,
                command: intent_result.action,
                raw_input: content
              ).call
              if creation.success?
                transaction_draft = creation.draft
              else
                direct_answer = "I understood the expense, but I could not create its review card: #{creation.errors.to_sentence}. Nothing changed."
              end
            else
              transaction_draft = HouseholdFinance::TransactionDraftBuilder.new(
                current_household,
                resolved_content,
                annual_budget_manager: annual_budget_manager,
                plan_prepared: true,
                raw_input: content
              ).call
            end
            annual_plan = annual_plan_for_transaction_draft(transaction_draft, annual_budget_manager) if transaction_draft
          when "transaction_draft_action"
            if intent_result.actionable?
              if intent_result.action.to_h[:type] == "ignore_transaction_drafts"
                ignored = HouseholdFinance::MiaTransactionDraftIgnorer.new(
                  current_household,
                  command: intent_result.action,
                  raw_input: content
                ).call
                direct_answer = ignored.response
                annual_plan = annual_budget_manager.plan_data if ignored.success?
              else
                draft_edit = HouseholdFinance::MiaTransactionDraftEditor.new(current_household, command: intent_result.action).call
                if draft_edit.success?
                  transaction_draft = draft_edit.draft
                  transaction_draft_answer = draft_edit.response
                  annual_plan = annual_plan_for_transaction_draft(transaction_draft, annual_budget_manager)
                else
                  direct_answer = draft_edit.response
                end
              end
            else
              direct_answer = clarification_answer(intent_result)
            end
          when "transaction_lookup"
            transaction_lookup_answer = HouseholdFinance::TransactionLookupAnswerer.new(current_household, resolved_content).call
          when "pending_drafts"
            pending_draft_answer = HouseholdFinance::PendingDraftAnswerer.new(current_household, resolved_content).call
          when "coaching", "general"
            coach_answerer = HouseholdFinance::MiaCoachAnswerer.new(
              current_household,
              resolved_content,
              annual_budget_manager: annual_budget_manager,
              reference_month: budget_month_param
            )
            coach_answer = coach_answerer.call
            annual_plan = coach_answerer.prepared_annual_plan || annual_plan
          end
        end

        {
          routed_content: resolved_content,
          followup: nil,
          direct_answer: direct_answer,
          pending_draft_answer: pending_draft_answer,
          action_result: action_result,
          coach_answer: coach_answer,
          transaction_lookup_answer: transaction_lookup_answer,
          spending_report: spending_report,
          annual_plan: action_result&.annual_plan || annual_plan,
          budget_answer: budget_answer,
          transaction_draft: transaction_draft,
          transaction_draft_answer: transaction_draft_answer
        }
      end

      def route_legacy_message(content, conversation_context:, annual_budget_manager:)
        followup = HouseholdFinance::ConversationFollowupResolver.new(content, conversation_context: conversation_context).call
        if HouseholdFinance::MiaTransactionDraftIgnorer.explicit_all_request?(content)
          ignored = HouseholdFinance::MiaTransactionDraftIgnorer.new(
            current_household,
            command: { type: "ignore_transaction_drafts", all_pending: true },
            raw_input: content
          ).call
          return legacy_transaction_route_payload(
            followup,
            annual_budget_manager: annual_budget_manager,
            direct_answer: ignored.response
          )
        end
        transaction_correction = legacy_transaction_correction_route(content, annual_budget_manager: annual_budget_manager, followup: followup)
        return transaction_correction if transaction_correction

        if confirmation_message?(content)
          return route_persisted_confirmation(
            content,
            conversation_context: conversation_context,
            annual_budget_manager: annual_budget_manager,
            followup: followup
          )
        end

        routed_content = followup.message
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
        annual_plan ||= annual_budget_manager.plan_data

        {
          routed_content: routed_content,
          followup: followup,
          direct_answer: nil,
          pending_draft_answer: pending_draft_answer,
          action_result: action_result,
          coach_answer: coach_answer,
          transaction_lookup_answer: transaction_lookup_answer,
          spending_report: spending_report,
          annual_plan: annual_plan,
          budget_answer: budget_answer,
          transaction_draft: transaction_draft,
          transaction_draft_answer: nil
        }
      end

      def legacy_transaction_correction_route(content, annual_budget_manager:, followup:)
        text = content.to_s.squish
        correction_like = text.match?(/\b(?:actually|change|update|correct)\b.*\b(?:yesterday|date|merchant|amount|category|split|transaction|draft)\b/i) ||
          text.match?(/\bwasn['’]?t\s+today\b.*\byesterday\b/i)
        return unless correction_like

        pending = current_household.transaction_drafts.pending.recent_first.limit(2).to_a
        return if pending.empty?
        if pending.many?
          return legacy_transaction_route_payload(
            followup,
            annual_budget_manager: annual_budget_manager,
            direct_answer: "I found more than one pending transaction review. Name the merchant you want to correct, or use Edit on its review card. Nothing changed."
          )
        end

        if text.match?(/\byesterday\b/i)
          edit = HouseholdFinance::MiaTransactionDraftEditor.new(
            current_household,
            command: { draft_id: pending.first.id, occurred_on: Date.current.prev_day.iso8601 }
          ).call
          return legacy_transaction_route_payload(
            followup,
            annual_budget_manager: annual_budget_manager,
            direct_answer: edit.success? ? nil : edit.response,
            transaction_draft: edit.success? ? edit.draft : nil,
            transaction_draft_answer: edit.success? ? edit.response : nil
          )
        end

        legacy_transaction_route_payload(
          followup,
          annual_budget_manager: annual_budget_manager,
          direct_answer: "I could not safely resolve every field in that correction. Use Edit on the pending review card or restate the merchant and replacement value. Nothing changed."
        )
      end

      def legacy_transaction_route_payload(followup, annual_budget_manager:, direct_answer:, transaction_draft: nil, transaction_draft_answer: nil)
        annual_plan = if transaction_draft
          annual_plan_for_transaction_draft(transaction_draft, annual_budget_manager)
        else
          annual_budget_manager.plan_data
        end
        {
          routed_content: followup.message,
          followup: followup,
          direct_answer: direct_answer,
          pending_draft_answer: nil,
          action_result: nil,
          coach_answer: nil,
          transaction_lookup_answer: nil,
          spending_report: nil,
          annual_plan: annual_plan,
          budget_answer: nil,
          transaction_draft: transaction_draft,
          transaction_draft_answer: transaction_draft_answer
        }
      end

      def route_persisted_confirmation(content, conversation_context:, annual_budget_manager:, followup:)
        topic = conversation_context[:active_topic].to_h.deep_symbolize_keys
        command = topic[:action].to_h.deep_symbolize_keys
        if topic[:status] == "pending_review" && topic[:mia_action_draft_id].to_i.positive?
          command = command.merge(type: "review_pending_action", draft_id: topic[:mia_action_draft_id])
        elsif command[:type].blank?
          pending_reviews = annual_budget_manager.plan_data.fetch(:pending_mia_action_drafts)
          if pending_reviews.one? && topic[:type].to_s.in?(%w[budget_edit budget_report])
            command = { type: "review_pending_action", draft_id: pending_reviews.first.fetch(:id), year: annual_budget_manager.year }
          end
        end

        action_result = if command[:type].present?
          HouseholdFinance::MiaActionDraftBuilder.new(
            current_household,
            user: current_user,
            annual_budget_manager: annual_budget_manager,
            selected_month: budget_month_param,
            raw_input: content,
            command: command
          ).call
        end
        direct_answer = if action_result.nil?
          "I lost the exact request, and I do not want to guess. Please restate the category, amount, and month you want changed. Nothing changed."
        end

        {
          routed_content: followup.message,
          followup: followup,
          direct_answer: direct_answer,
          pending_draft_answer: nil,
          action_result: action_result,
          coach_answer: nil,
          transaction_lookup_answer: nil,
          spending_report: nil,
          annual_plan: action_result&.annual_plan || annual_budget_manager.plan_data,
          budget_answer: nil,
          transaction_draft: nil,
          transaction_draft_answer: nil
        }
      end

      def confirmation_message?(content)
        content.to_s.squish.match?(/\A(?:yes|yeah|yep|yup)(?:[\s,!.]+(?:please|do that|do it|draft that|make that change|go ahead))*[\s,!.]*\z|\A(?:please\s+)?(?:do that|do it|draft that|make that change|go ahead)[\s,!.]*\z/i)
      end

      def resolved_conversation_turn(intent_result)
        return unless intent_result

        topic = intent_result.topic.to_h.deep_symbolize_keys
        action = intent_result.action.to_h.deep_symbolize_keys
        {
          schema_version: 2,
          type: topic[:type],
          title: topic[:title],
          subject: topic[:subject],
          intent: intent_result.intent,
          confidence: intent_result.confidence,
          resolved_message: intent_result.resolved_message,
          action: action[:type] == "none" ? nil : action
        }.compact
      end

      def resolved_conversation_context(conversation_context, resolved_turn)
        return conversation_context unless resolved_turn

        conversation_context.deep_symbolize_keys.merge(
          active_topic: resolved_turn,
          resolved_current_turn: resolved_turn,
          resolution_rule: "Use resolved_current_turn for the participant's current conversational meaning. Recent database facts remain authoritative for money truth."
        )
      end

      def clarification_answer(intent_result)
        intent_result.clarification.presence || "I want to make sure I have the right request. Please name the category, amount, and month you want to change. Nothing changed yet."
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

      def assistant_content_for(content, history, annual_plan, spending_report, transaction_draft, transaction_draft_answer, budget_answer, transaction_lookup_answer, pending_draft_answer, coach_answer, action_result, conversation_context, direct_answer: nil, conversation_resolution: nil)
        return direct_answer if direct_answer.present?

        if action_result
          write_state = action_result.proposal || action_result.existing_draft ? "pending_review" : "no_write"
          return narrate_structured_answer(
            content,
            history,
            conversation_context,
            kind: "budget_action",
            fallback_response: action_result.response,
            annual_plan: annual_plan,
            write_state: write_state,
            mia_action_result: action_result
          )
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
          draft_answer = transaction_draft_answer.presence || drafted_transaction_message(transaction_draft)
          kind = transaction_draft_answer.present? ? "transaction_draft_update" : "transaction_draft"
          write_state = transaction_draft_answer.present? ? "draft_updated" : "pending_review"
          return narrate_structured_answer(content, history, conversation_context, kind: kind, fallback_response: draft_answer, annual_plan: annual_plan, transaction_draft: transaction_draft, write_state: write_state, selected_month: transaction_draft.occurred_on.month)
        end

        context = HouseholdFinance::MiaContextBuilder.new(
          current_household,
          annual_plan: annual_plan,
          reference_month: budget_month_param,
          conversation_context: conversation_context
        ).call
        response_history = conversation_resolution&.dig(:intent) == "recall" ? [] : history
        ::Demo::MiaResponder.new.call(
          content,
          history: response_history,
          context: context,
          draft_capable: false,
          conversation_resolution: conversation_resolution
        )
      end

      def narrate_structured_answer(content, history, conversation_context, kind:, fallback_response:, write_state:, annual_plan: nil, spending_report: nil, transaction_draft: nil, mia_action_result: nil, selected_month: nil)
        answer_packet = HouseholdFinance::MiaAnswerPacketBuilder.new(
          kind: kind,
          fallback_response: fallback_response,
          write_state: write_state,
          selected_month: selected_month || budget_month_param,
          annual_plan: annual_plan,
          spending_report: spending_report,
          transaction_draft: transaction_draft,
          conversation_context: conversation_context,
          mia_action_result: mia_action_result
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

      def update_conversation_state(session, intent_result:, user_message:, assistant_message:, mia_action_draft:, transaction_draft:)
        HouseholdFinance::MiaConversationStateUpdater.new(
          session,
          intent_result: intent_result,
          user_message: user_message,
          assistant_message: assistant_message,
          mia_action_draft: mia_action_draft,
          transaction_draft: transaction_draft
        ).call
      rescue StandardError => e
        Rails.logger.warn("Mia conversation state could not be saved chat_session_id=#{session&.id}: #{e.class}: #{e.message}")
        false
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
