module Api
  module V1
    class MiaMessagesController < BaseController
      ATTACHMENT_ACTION_VERB_SOURCE = "set|change|update|increase|decrease|lower|raise|move|create|add(?!\\s+up\\b)|rename|archive|restore|schedule|end|stop|link|unlink|reconcile".freeze
      ATTACHMENT_ACTION_NOUN_SOURCE = "budget|category|allocation|income|goal|household|runway|expense|spending|debt|asset|account|bank".freeze
      ATTACHMENT_ACTION_VERB_PATTERN = /\b(?:#{ATTACHMENT_ACTION_VERB_SOURCE})\b/i.freeze
      ATTACHMENT_ACTION_NOUN_PATTERN = /\b(?:#{ATTACHMENT_ACTION_NOUN_SOURCE})\b/i.freeze
      ATTACHMENT_ACTION_REQUEST_PREFIX_SOURCE = "(?:(?:and|also|then|and\\s+then)\\s*[,;:]?\\s*)?(?:please\\s+)?(?:(?:(?:can|could|would|will)\\s+you(?:\\s+please)?|i\\s+(?:want|need)(?:\\s+you)?\\s+to|i(?:'d|\\s+would)\\s+like\\s+to|help\\s+me)\\s+)?".freeze
      ATTACHMENT_INFORMATIONAL_FRAME_PATTERN = /\A\s*#{ATTACHMENT_ACTION_REQUEST_PREFIX_SOURCE}(?:update\s+me\b|tell\s+me\b|explain\b|increase\s+(?:my|our)\s+understanding\b)/i.freeze
      ATTACHMENT_NAMED_AMOUNT_PATTERN = /\A\s*#{ATTACHMENT_ACTION_REQUEST_PREFIX_SOURCE}(?:set|change|update|increase|decrease|lower|raise)\s+[^?!.;,\r\n]{1,60}?\s+(?:to|at|by)\s+\$?\d[\d,]*(?:\.\d{1,2})?(?:\s*(?:dollars?|monthly|per\s+month))?\s*[?!.;]*\z/i.freeze

      before_action :authenticate_user!
      before_action :require_writable_household!, only: %i[create destroy]

      def index
        render json: current_data_presenter.mia(
          before_id: params[:before_id],
          limit: params[:limit]
        )
      end

      def create
        @mia_request_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        content = params[:message].to_s.strip
        # Emergency guidance must not depend on uploads being available. Do not
        # resolve or expose attachments for this boundary response.
        if content.present? && content.length <= ChatMessage::MAX_CONTENT_LENGTH && ::Mia::CrisisBoundary.matches?(content)
          session = current_chat_session
          return if render_preexisting_message_request(session, content, [])
          message_request, request_handled = reserve_message_request(session, content, [])
          return if request_handled
          @active_mia_message_request = message_request
          return render_crisis_response(session, content, [], message_request: message_request)
        end

        if attachment_limit_exceeded?
          return render json: { errors: [ "Attach up to 5 uploads to one Mia message." ] }, status: :unprocessable_entity
        end
        attached_imports = attached_document_imports
        if unavailable_attachment_ids.any?
          return render json: { errors: [ "One or more attached uploads are unavailable in this household." ] }, status: :unprocessable_entity
        end
        content = "Please review this upload." if content.blank? && attached_imports.any?
        return render json: { errors: [ "Message can't be blank" ] }, status: :unprocessable_entity if content.blank?
        return render json: { errors: [ "Message is too long (maximum is #{ChatMessage::MAX_CONTENT_LENGTH} characters)" ] }, status: :unprocessable_entity if content.length > ChatMessage::MAX_CONTENT_LENGTH

        session = current_chat_session
        return if render_preexisting_message_request(session, content, attached_imports)

        invalid_evidence = invalid_prior_document_evidence(session)
        if attached_imports.empty? && invalid_evidence && evidence_style_continuation?(
          content,
          invalid_evidence.fetch(:document_imports),
          prior_query_scope: invalid_evidence[:query_scope]
        )
          HouseholdFinance::MiaDocumentEvidenceStateUpdater.retire(session)
          return render json: {
            error: "I can’t use the prior upload for this follow-up because it is no longer ready or available. Re-upload the document, then ask again.",
            code: "mia_document_evidence_unavailable"
          }, status: :conflict
        end
        message_request, request_handled = reserve_message_request(session, content, attached_imports)
        return if request_handled
        @active_mia_message_request = message_request

        if attached_imports.empty? && (memory_command = mia_memory_command(content))
          return render_mia_memory_command(
            session,
            content,
            memory_command,
            message_request: message_request,
            retire_prior_document_evidence: document_evidence_topic_present?(session)
          )
        end

        transcript = HouseholdFinance::ConversationTranscriptBuilder.new(
          session,
          persona_version_id: current_persona.version_id,
          cohort_id: current_participant_runtime.cohort_id,
          cohort_release_id: current_participant_runtime.release_id
        ).call
        transcript = transcript_for_current_persona(transcript)
        transcript = intent_transcript_without_memory_commands(transcript)
        history = transcript.map { |message| message.slice(:role, :content) }
        @mia_conversation_messages = history

        annual_budget_manager = HouseholdFinance::AnnualBudgetManager.new(current_household, year: budget_year_param)
        intent_plan = annual_budget_manager.read_only_plan_data
        global_read_only_request = ::Mia::FinancialReadOnlyRequest.matches?(content)
        conversation_context = HouseholdFinance::ConversationContextBuilder.new(
          session,
          household: current_household,
          persona_context_id: current_participant_runtime.continuity_id
        ).call
        prior_evidence = prior_document_evidence(conversation_context)
        prior_evidence_imports = prior_evidence.fetch(:document_imports)
        if attached_imports.empty? && prior_evidence_imports.any?
          followup = HouseholdFinance::AttachedDocumentFollowupResolver.new(
            current_household,
            message: content,
            document_imports: prior_evidence_imports,
            prior_query_scope: prior_evidence[:query_scope]
          ).call
          if followup
            return render_prior_document_evidence_response(
              session,
              content,
              followup,
              prior_evidence_imports,
              message_request: message_request,
              annual_plan: intent_plan
            )
          end
        end
        retire_prior_document_evidence = attached_imports.empty? && document_evidence_topic_present?(session)
        conversation_context = HouseholdFinance::DocumentEvidenceContinuity.without_evidence(conversation_context) if retire_prior_document_evidence
        intent_context = HouseholdFinance::MiaIntentContextBuilder.new(
          current_household,
          annual_plan: intent_plan,
          conversation_context: conversation_context,
          transcript: transcript,
          selected_month: budget_month_param
        ).call
        intent_result = prompt_injection_intent_result(content, intent_context: intent_context) || setup_guide_intent_result(content)
        intent_result ||= HouseholdFinance::MiaIntentResolver.new(
          user_message: content,
          context: intent_context
        ).call
        if intent_result.nil? && global_read_only_request
          intent_result = HouseholdFinance::MiaIntentResolver::Result.new(
            intent: "coaching", confidence: 1.0, continuation: false,
            resolved_message: content, needs_clarification: false, clarification: "",
            topic: {}, action: { type: "none" }, read_only_plan: {}, source: "deterministic"
          )
        end
        if attached_imports.any?
          return render_attached_document_response(
            session,
            content,
            attached_imports,
            message_request: message_request,
            history: history,
            intent_result: intent_result,
            conversation_context: conversation_context,
            annual_budget_manager: annual_budget_manager,
            annual_plan: intent_plan
          )
        end

        if intent_result
          intent_plan = annual_budget_manager.plan_data unless global_read_only_request || intent_result.read_only_plan? || HouseholdFinance::MiaCoachAnswerer.prompt_injection?(content)
          routed = route_model_intent(
            intent_result,
            content: content,
            conversation_context: conversation_context,
            annual_budget_manager: annual_budget_manager,
            annual_plan: intent_plan
          )
        else
          intent_plan = annual_budget_manager.plan_data
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
        assistant_presentation = routed[:presentation] || {}
        intent_direct_answer, assistant_presentation = apply_persona_capability_boundary(
          content,
          direct_answer: intent_direct_answer,
          presentation: assistant_presentation
        )
        intent_direct_answer, assistant_presentation = apply_prompt_injection_boundary(
          content,
          direct_answer: intent_direct_answer,
          presentation: assistant_presentation
        )
        conversation_resolution = resolved_conversation_turn(intent_result)
        response_conversation_context = resolved_conversation_context(conversation_context, conversation_resolution)
        response_conversation_context[:personalization_memory] = HouseholdFinance::MiaMemoryContextBuilder.new(
          current_household,
          user: current_user
        ).call
        @approved_coach_content = ::Mia::ApprovedContentRetriever.new(persona: current_persona, query: content).call

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
        assistant_content = append_persona_capability_boundary(content, assistant_content)
        assistant_content = append_prompt_injection_boundary(content, assistant_content)
        user_message, assistant_message = persist_chat_messages(
          session,
          content,
          attached_imports,
          assistant_content,
          assistant_presentation: assistant_presentation
        )
        mia_action_draft = action_result&.existing_draft || persist_mia_action_draft(action_result, user_message, assistant_message)
        if action_result&.proposal && mia_action_draft.nil?
          assistant_message.update!(content: action_draft_persistence_failure_message)
          assistant_message.coach_content_citations.delete_all
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
            transaction_draft: transaction_draft,
            persona_context_id: current_participant_runtime.continuity_id
          )
        else
          compact_conversation(
            session,
            user_message,
            assistant_message,
            follow_up: followup.follow_up?,
            persona_context_id: current_participant_runtime.continuity_id
          )
        end
        retire_document_evidence_state(session) if retire_prior_document_evidence

        response_payload = {
          user_message: serialize_chat_message(user_message, author: "You"),
          assistant_message: serialize_chat_message(assistant_message),
          transaction_draft: transaction_draft ? serialize_transaction_draft(transaction_draft) : nil,
          mia_action_draft: mia_action_draft ? serialize_mia_action_draft(mia_action_draft, selected_item_ids: action_result&.selected_item_ids) : nil,
          budget: annual_plan && !global_read_only_request && !intent_result&.read_only_plan? && !HouseholdFinance::MiaCoachAnswerer.prompt_injection?(content) ? current_data_presenter(household: current_household.reload, annual_plan: annual_plan).budget : nil,
          spending_report: spending_report
        }
        complete_message_request(message_request, response_payload)
        record_mia_operation("mia.request.completed", assistant_message: assistant_message, attached_imports: attached_imports, transaction_draft: transaction_draft, mia_action_draft: mia_action_draft)
        render json: response_payload, status: :created
      rescue StandardError => error
        fail_active_message_request(error)
        record_mia_operation("mia.request.failed", error_code: error.class.name)
        raise
      end

      def destroy
        if (session = current_household.chat_sessions.find_by(user: current_user))
          session.with_lock do
            session.mia_message_requests.where(status: "processing").find_each(&:expire_if_stale!)
            if session.mia_message_requests.where(status: "processing").exists?
              render json: {
                error: "Mia is still working on a message. Wait for it to finish before clearing this conversation.",
                code: "mia_request_processing"
              }, status: :conflict
              return
            end

            session.chat_messages.delete_all
            session.mia_message_requests.delete_all
            session.update!(rolling_summary: nil, open_topics: [], active_topic: {}, last_compacted_message_id: nil, last_compacted_at: nil)
          end
        end
        head :no_content
      end

      private

      def render_crisis_response(session, content, attached_imports, message_request:)
        user_message, assistant_message = persist_chat_messages(session, content, attached_imports, ::Mia::CrisisBoundary.response)
        payload = {
          user_message: serialize_chat_message(user_message, author: "You"),
          assistant_message: serialize_chat_message(assistant_message),
          mia_action_draft: nil, transaction_draft: nil, budget: nil, spending_report: nil
        }
        complete_message_request(message_request, payload)
        record_mia_operation("mia.request.completed", assistant_message: assistant_message, attached_imports: attached_imports)
        render json: payload, status: :created
      end

      def transcript_for_current_persona(transcript)
        Array(transcript).filter_map do |message|
          content = ::Mia::LanguagePolicy.redact_unauthorized_phrase_artifacts(
            message[:content],
            persona: current_persona
          )
          next if content.blank?

          message.merge(content: content)
        end
      end

      def intent_transcript_without_memory_commands(transcript)
        source_ids = current_household.household_memories
          .where(owner_user: current_user, source_kind: "mia_command")
          .where.not(source_chat_message_id: nil)
          .pluck(:source_chat_message_id)
        excluded_ids = source_ids.to_set
        transcript.each_with_index do |message, index|
          memory_command_turn = message[:role] == "user" && mia_memory_command(message[:content]).present?
          next unless excluded_ids.include?(message[:id]) || memory_command_turn

          excluded_ids << message[:id]
          acknowledgement = transcript[index + 1]
          excluded_ids << acknowledgement[:id] if acknowledgement&.dig(:role) == "assistant"
        end
        transcript.reject { |message| excluded_ids.include?(message[:id]) }
      end

      def mia_memory_command(content)
        normalized = content.to_s.squish
        return { type: :list } if normalized.match?(/\A(?:what|which) (?:things? )?(?:does mia|do you) remember(?: about me| about us)?\??\z/i)

        match = normalized.match(/\A(?:please )?remember(?: that| this)?[,:]?\s+(.+)\z/i)
        return unless match

        value = match[1].to_s.squish
        return { type: :invalid } if value.blank? || value.length > HouseholdMemory::MAX_DISPLAY_LENGTH
        return { type: :unsafe } if HouseholdFinance::MiaCoachAnswerer.unsafe_memory_instruction?(value)

        { type: :create, value: value }
      end

      def render_mia_memory_command(session, content, command, message_request:, retire_prior_document_evidence:)
        case command.fetch(:type)
        when :list
          assistant_content = mia_memory_list_answer
          user_message, assistant_message = persist_chat_messages(session, content, [], assistant_content)
        when :invalid
          assistant_content = "Tell me one thing to remember in #{HouseholdMemory::MAX_DISPLAY_LENGTH} characters or fewer. I will show it under My Profile so you can change or forget it anytime."
          user_message, assistant_message = persist_chat_messages(session, content, [], assistant_content)
        when :unsafe
          assistant_content = "I can’t save an instruction that bypasses review or automatically approves or applies changes. Nothing was approved or applied, and no memory was saved."
          user_message, assistant_message = persist_chat_messages(session, content, [], assistant_content)
        when :create
          user_message, assistant_message, memory = persist_mia_memory_command(session, content, command.fetch(:value), message_request)
        end

        response_payload = {
          user_message: serialize_chat_message(user_message, author: "You"),
          assistant_message: serialize_chat_message(assistant_message),
          transaction_draft: nil,
          mia_action_draft: nil,
          budget: nil,
          spending_report: nil,
          memory: memory&.as_api_json(viewer: current_user)
        }
        retire_document_evidence_state(session) if retire_prior_document_evidence
        complete_message_request(message_request, response_payload)
        record_mia_operation("mia.request.completed", assistant_message: assistant_message)
        render json: response_payload, status: :created
      end

      def persist_mia_memory_command(session, content, value, message_request)
        ApplicationRecord.transaction do
          membership = current_household.household_memberships.lock.find_by!(user_id: current_user.id)
          if membership.mia_personalization_paused?
            answer = "Personalization is paused, so I did not save that. Resume it under My Profile → What Mia remembers, then ask me again. Your approved financial records still work normally."
            user_message, assistant_message = persist_chat_messages(session, content, [], answer)
            next [ user_message, assistant_message, nil ]
          end
          if current_household.household_memories.where(owner_user: current_user).count >= HouseholdMemory::MAX_STORED_PER_OWNER
            answer = "You already have #{HouseholdMemory::MAX_STORED_PER_OWNER} saved memories. I did not add another. Open My Profile → What Mia remembers and forget one you no longer need."
            user_message, assistant_message = persist_chat_messages(session, content, [], answer)
            next [ user_message, assistant_message, nil ]
          end

          category = mia_memory_category(value)
          sensitive = mia_memory_sensitive?(value)
          needs_confirmation = sensitive || category.in?(%w[goal preference constraint])
          status = needs_confirmation ? "pending_confirmation" : "user_confirmed"
          answer = if needs_confirmation
            reason = sensitive ? "as sensitive " : ""
            "I saved that #{reason}and left it waiting for your confirmation. Review it under My Profile → What Mia remembers before I use it."
          else
            "I’ll remember that for future coaching. You can review, edit, pause, or forget it anytime under My Profile → What Mia remembers. It will not override your approved financial records."
          end
          user_message, assistant_message = persist_chat_messages(session, content, [], answer)
          memory = current_household.household_memories.create!(
            owner_user: current_user,
            source_chat_message: user_message,
            source_kind: "mia_command",
            request_key: message_request ? "mia:#{message_request.request_key}" : "mia-message:#{user_message.id}",
            category: category,
            status: status,
            sensitivity: sensitive ? "sensitive" : "ordinary",
            visibility: "private",
            display_value: value,
            confirmed_at: status == "user_confirmed" ? Time.current : nil
          )
          current_household.household_audit_events.create!(
            user: current_user, actor_type: "user", event_type: "mia_memory.created",
            occurred_at: Time.current,
            metadata: { memory_id: memory.id, category: memory.category, visibility: memory.visibility, status: memory.status, source: "mia_command" }
          )
          [ user_message, assistant_message, memory ]
        end
      end

      def mia_memory_list_answer
        membership = current_household.household_memberships.find_by!(user_id: current_user.id)
        memories = current_household.household_memories.visible_to(current_user).active.ordered.limit(HouseholdMemory::MAX_ACTIVE_CONTEXT)
        return "Personalization is paused. I still keep the choices shown under My Profile → What Mia remembers, but I am not using them in replies." if membership.mia_personalization_paused?
        return "I do not have any active saved memories for you. I do not mine chat history. Say “Remember that…” or add one under My Profile → What Mia remembers." if memories.empty?

        lines = memories.map.with_index { |memory, index| "#{index + 1}. #{memory.display_value} (#{memory.category.humanize.downcase}, only me)" }
        "Here is what I actively remember for personalization:\n#{lines.join("\n")}\nThese are coaching context, not financial truth. You can edit or forget them under My Profile."
      end

      def mia_memory_category(value)
        normalized = value.downcase
        return "coaching_style" if normalized.match?(/\b(?:coach(?:ing)?|tone|repl(?:y|ies)|responses?|questions?|language|explain(?:s|ed|ing)?|explanations?)\b/)
        return "follow_up" if normalized.match?(/\b(?:follow[ -]?ups?|check[ -]?ins?|remind(?:s|ed|ing|ers?)?)\b/)
        return "goal" if normalized.match?(/\bgoals?\b|\bworking towards?\b|\bwant to achieve\b/)
        return "constraint" if normalized.match?(/\b(?:cannot|can't|must not|do not|don't|avoid|constraints?|limits?)\b/)
        return "habit" if normalized.match?(/\b(?:usually|habits?)\b|\bevery (?:day|week|month)\b/)

        "preference"
      end

      def mia_memory_sensitive?(value)
        value.downcase.match?(
          /\b(?:health|medical|diagnos(?:e|ed|es|ing|is|ises|tic|tics)?|disabil(?:ity|ities|ed)|pregnan(?:t|cy|cies)|fertil(?:e|ity|ization|isation|ized|ised)?|religions?|politics?|political|sexual|gender|pronouns?|race|ethnic|ethnicity|trauma|abuse|addiction)\b/
        )
      end

      def setup_guide_intent_result(content)
        guide = HouseholdFinance::MiaSetupGuide.new(current_household)
        message = guide.setup_request_message(content)
        return unless message

        next_field = guide.next_missing_field
        label = HouseholdFinance::SetupStatus::FIELD_LABELS[next_field&.to_sym]
        HouseholdFinance::MiaIntentResolver::Result.new(
          intent: "clarification",
          confidence: 1.0,
          continuation: false,
          resolved_message: content,
          needs_clarification: true,
          clarification: message,
          topic: {
            type: "household_setup",
            title: "Starting household picture",
            subject: label || "Setup complete"
          },
          action: { type: "none" },
          read_only_plan: {},
          source: "deterministic"
        )
      end

      def prompt_injection_intent_result(content, intent_context:)
        return unless HouseholdFinance::MiaCoachAnswerer.prompt_injection?(content)

        safe_scenario = HouseholdFinance::MiaIntentResolver.deterministic_scenario_result_for(
          user_message: content,
          context: intent_context
        )
        return safe_scenario if safe_scenario&.read_only_plan?

        HouseholdFinance::MiaIntentResolver::Result.new(
          intent: "general",
          confidence: 1.0,
          continuation: false,
          resolved_message: content,
          needs_clarification: false,
          clarification: "",
          topic: {
            type: "coaching",
            title: "Safety boundary",
            subject: "Household CFO boundaries"
          },
          action: { type: "none" },
          read_only_plan: {},
          source: "deterministic"
        )
      end

      def budget_year_param
        return Date.current.year if params[:year].blank?

        params[:year].to_i.clamp(2000, 2100)
      end

      def budget_month_param
        return Date.current.month if params[:month].blank?

        params[:month].to_i.clamp(1, 12)
      end

      def render_attached_document_response(session, content, attached_imports, message_request:, history:, intent_result:,
        conversation_context:, annual_budget_manager:, annual_plan:)
        processed_imports = process_attached_imports(attached_imports)
        evidence_prompt = attached_document_evidence_prompt(content, intent_result)
        evidence_scope = attached_document_query_scope(evidence_prompt, processed_imports)
        evidence_content = attached_document_message(evidence_prompt, processed_imports)
        if supported_attached_action_intent?(intent_result)
          return render_attached_action_response(
            session,
            content,
            processed_imports,
            evidence_content: evidence_content,
            evidence_scope: evidence_scope,
            message_request: message_request,
            history: history,
            intent_result: intent_result,
            conversation_context: conversation_context,
            annual_budget_manager: annual_budget_manager,
            annual_plan: annual_plan
          )
        end

        boundary = attachment_action_boundary(intent_result, conversation_context)
        assistant_content = [ evidence_content, boundary ].compact_blank.join(" ")
        user_message, assistant_message = ApplicationRecord.transaction do
          [
            session.chat_messages.create!(user_message_attributes(content, processed_imports)),
            assistant_message_writer(session).create!(content: assistant_content.to_s.truncate(ChatMessage::MAX_ASSISTANT_CONTENT_LENGTH, omission: "…"))
          ]
        end
        persist_document_evidence_state(
          session,
          processed_imports,
          user_message,
          assistant_message,
          query_scope: evidence_scope,
          activate: !structured_conversation_topic?(conversation_context)
        )

        response_payload = {
          user_message: serialize_chat_message(user_message, author: "You"),
          assistant_message: serialize_chat_message(assistant_message),
          transaction_draft: nil,
          mia_action_draft: nil,
          budget: nil,
          spending_report: nil
        }
        complete_message_request(message_request, response_payload)
        record_mia_operation("mia.request.completed", assistant_message: assistant_message, attached_imports: processed_imports)
        render json: response_payload, status: :created
      end

      def render_attached_action_response(session, content, processed_imports, evidence_content:, evidence_scope:, message_request:, history:,
        intent_result:, conversation_context:, annual_budget_manager:, annual_plan:)
        action_result = nil
        combined_content = nil
        user_message = nil
        assistant_message = nil
        mia_action_draft = nil
        draft_persistence_error = nil
        no_draft_result = false

        ApplicationRecord.transaction do
          routed = route_model_intent(
            intent_result,
            content: content,
            conversation_context: conversation_context,
            annual_budget_manager: annual_budget_manager,
            annual_plan: annual_plan
          )
          action_result = routed[:action_result]
          action_content = assistant_content_for(
            content,
            history,
            routed[:annual_plan],
            routed[:spending_report],
            routed[:transaction_draft],
            routed[:transaction_draft_answer],
            routed[:budget_answer],
            routed[:transaction_lookup_answer],
            routed[:pending_draft_answer],
            routed[:coach_answer],
            action_result,
            conversation_context,
            direct_answer: routed[:direct_answer],
            conversation_resolution: resolved_conversation_turn(intent_result)
          )
          combined_content = [ evidence_content, "Separately, #{action_content}" ].compact_blank.join(" ")
          user_message, assistant_message = persist_chat_messages(session, content, processed_imports, combined_content)
          mia_action_draft = action_result&.existing_draft
          if mia_action_draft.nil? && action_result&.proposal
            begin
              mia_action_draft = action_result.proposal.create_draft!(
                source_chat_message: user_message,
                assistant_chat_message: assistant_message
              )
            rescue StandardError => e
              draft_persistence_error = e
              raise ActiveRecord::Rollback
            end
          elsif mia_action_draft.nil?
            no_draft_result = true
            raise ActiveRecord::Rollback
          end
        end

        if draft_persistence_error
          Rails.logger.error(
            "Mia attachment action draft could not be persisted: #{draft_persistence_error.class}: #{draft_persistence_error.message}"
          )
          combined_content = [ evidence_content, action_draft_persistence_failure_message ].compact_blank.join(" ")
          @used_coach_content = []
          user_message, assistant_message = persist_chat_messages(session, content, processed_imports, combined_content)
        elsif no_draft_result
          user_message, assistant_message = persist_chat_messages(session, content, processed_imports, combined_content)
        end
        response_budget = if mia_action_draft
          annual_plan = HouseholdFinance::AnnualBudgetManager.new(current_household, year: mia_action_draft.year).plan_data
          current_data_presenter(household: current_household.reload, annual_plan: annual_plan, ensure_plan: false).budget
        end
        update_conversation_state(
          session,
          intent_result: intent_result,
          user_message: user_message,
          assistant_message: assistant_message,
          mia_action_draft: mia_action_draft,
          transaction_draft: nil,
          persona_context_id: current_participant_runtime.continuity_id
        )
        persist_document_evidence_state(
          session,
          processed_imports,
          user_message,
          assistant_message,
          query_scope: evidence_scope,
          activate: false
        )

        response_payload = {
          user_message: serialize_chat_message(user_message, author: "You"),
          assistant_message: serialize_chat_message(assistant_message),
          transaction_draft: nil,
          mia_action_draft: mia_action_draft ? serialize_mia_action_draft(mia_action_draft, selected_item_ids: action_result&.selected_item_ids) : nil,
          budget: response_budget,
          spending_report: nil
        }
        complete_message_request(message_request, response_payload)
        record_mia_operation(
          "mia.request.completed",
          assistant_message: assistant_message,
          attached_imports: processed_imports,
          mia_action_draft: mia_action_draft
        )
        render json: response_payload, status: :created
      end

      def supported_attached_action_intent?(intent_result)
        return false unless intent_result
        return false unless intent_result.intent.in?(%w[action_plan budget_action household_action income_action debt_action asset_action goal_action])

        intent_result.action_plan? || intent_result.action.to_h[:type].to_s != "none"
      end

      def attachment_action_boundary(intent_result, conversation_context)
        action_type = intent_result&.action.to_h&.dig(:type).to_s
        structured_action = action_type.present? && action_type != "none"
        continuing_clarification = intent_result&.continuation && conversation_context.dig(:active_topic, :status).to_s == "needs_clarification"
        return unless structured_action || continuing_clarification || attachment_action_request?

        "I answered the upload part, but I could not safely prepare the separate requested household change in this turn. Nothing changed. Send the change as a new message without an attachment, and I’ll prepare a review card for you."
      end

      def attachment_action_request?(message = params[:message])
        return false if pure_attachment_review_request?(message)

        attachment_mutation_request?(message)
      end

      def pure_attachment_review_request?(message)
        normalized = message.to_s.squish
        generic_opening = normalized.match?(HouseholdFinance::AttachedDocumentQuestionAnswerer::GENERIC_REVIEW_PATTERN)
        return false unless generic_opening || HouseholdFinance::AttachedDocumentQuestionAnswerer.generic_review_request?(normalized)

        !attachment_mutation_request?(message)
      end

      def attachment_mutation_request?(message)
        attachment_request_segments(message).any? { |segment| attachment_mutation_segment?(segment) }
      end

      def attachment_mutation_segment?(segment)
        return false if segment.match?(ATTACHMENT_INFORMATIONAL_FRAME_PATTERN)

        direct_request = segment.match?(
          /\A\s*#{ATTACHMENT_ACTION_REQUEST_PREFIX_SOURCE}#{ATTACHMENT_ACTION_VERB_PATTERN.source}.{0,100}#{ATTACHMENT_ACTION_NOUN_PATTERN.source}/i
        )
        evidence_directed_request = segment.match?(
          /\A\s*(?:please\s+)?(?:use|import)\b.{0,100}\bto\s+#{ATTACHMENT_ACTION_VERB_PATTERN.source}.{0,100}#{ATTACHMENT_ACTION_NOUN_PATTERN.source}/i
        )
        direct_request || evidence_directed_request || segment.match?(ATTACHMENT_NAMED_AMOUNT_PATTERN)
      end

      def attachment_request_segments(message)
        message.to_s
          .gsub(/\R+/, ". ")
          .gsub(/([?!.;])(?=[[:alpha:]])/, '\\1 ')
          .split(
            /(?<=[?!.;])\s+|\s+\b(?:also|and then|then)\b\s*|\s+(?=and\s+#{ATTACHMENT_ACTION_REQUEST_PREFIX_SOURCE}#{ATTACHMENT_ACTION_VERB_PATTERN.source})/i
          )
      end

      def attached_document_evidence_prompt(content, intent_result)
        action_type = intent_result&.action.to_h&.dig(:type).to_s
        structured_action = action_type.present? && action_type != "none"
        return content unless structured_action || attachment_action_request?(content)

        segments = attachment_request_segments(content)
        evidence_segments = segments.reject do |segment|
          attachment_action_request?(segment)
        end.select do |segment|
          segment.match?(HouseholdFinance::AttachedDocumentQuestionAnswerer::SUBSTANTIVE_QUESTION_PATTERN) ||
            HouseholdFinance::AttachedDocumentQuestionAnswerer.generic_review_request?(segment)
        end
        evidence_segments.map { |segment| segment.strip.sub(/[?!.;]+\z/, "") }.join(" ").strip.presence
      end

      def prior_document_evidence(conversation_context)
        topics = [ conversation_context[:active_topic], *Array(conversation_context[:open_topics]) ].compact
        evidence = topics.filter_map { |topic| topic.to_h.deep_symbolize_keys[:document_evidence] }.first
        ids = Array(evidence&.dig(:financial_document_import_ids))
          .first(HouseholdFinance::DocumentEvidenceContinuity::MAX_IMPORTS)
          .filter_map { |id| Integer(id, exception: false) }
        return { document_imports: [], query_scope: nil } if ids.empty?

        imports = current_household.financial_document_imports
          .where(id: ids, status: HouseholdFinance::DocumentEvidenceContinuity::READY_STATUSES, source_deleted_at: nil)
          .index_by(&:id)
        return { document_imports: [], query_scope: nil } unless imports.length == ids.length

        {
          document_imports: ids.map { |id| imports.fetch(id.to_i) },
          query_scope: evidence[:query_scope]
        }
      end

      def invalid_prior_document_evidence(session)
        topic = [ session.active_topic, *Array(session.open_topics) ].find do |candidate|
          HouseholdFinance::DocumentEvidenceContinuity.topic?(candidate)
        end
        return unless topic

        stored = topic.to_h.deep_stringify_keys.fetch("document_evidence", {})
        ids = HouseholdFinance::DocumentEvidenceContinuity.stored_import_ids(stored)
        imports = current_household.financial_document_imports.where(id: ids).to_a
        ready_count = current_household.financial_document_imports
          .where(
            id: ids,
            status: HouseholdFinance::DocumentEvidenceContinuity::READY_STATUSES,
            source_deleted_at: nil
          )
          .count
        return if ids.any? && ready_count == ids.length

        { document_imports: imports, query_scope: stored["query_scope"] }
      end

      def evidence_style_continuation?(content, document_imports, prior_query_scope:)
        return true if HouseholdFinance::AttachedDocumentFollowupResolver.evidence_style_reference?(content)
        return true if HouseholdFinance::AttachedDocumentFollowupResolver.elliptical_scope_reference?(content, prior_query_scope)
        return false if document_imports.empty?

        HouseholdFinance::AttachedDocumentFollowupResolver.new(
          current_household,
          message: content,
          document_imports: document_imports
        ).call.present?
      end

      def document_evidence_topic_present?(session)
        [ session.active_topic, *Array(session.open_topics) ].any? do |topic|
          HouseholdFinance::DocumentEvidenceContinuity.topic?(topic)
        end
      end

      def structured_conversation_topic?(conversation_context)
        type = conversation_context.dig(:active_topic, :type).to_s
        type.present? && type != "document_evidence"
      end

      def render_prior_document_evidence_response(session, content, followup, document_imports, message_request:, annual_plan:)
        answer = HouseholdFinance::AttachedDocumentQuestionAnswerer.new(
          current_household,
          message: followup.prompt,
          document_imports: document_imports
        ).call
        assistant_content = "Using your prior upload#{'s' if document_imports.many?}, #{answer.to_s.sub(/\A./) { |character| character.downcase }}"
        user_message, assistant_message = persist_chat_messages(session, content, [], assistant_content)
        persist_document_evidence_state(
          session,
          document_imports,
          user_message,
          assistant_message,
          query_scope: followup.query_scope,
          activate: !structured_session_topic?(session)
        )

        response_payload = {
          user_message: serialize_chat_message(user_message, author: "You"),
          assistant_message: serialize_chat_message(assistant_message),
          transaction_draft: nil,
          mia_action_draft: nil,
          budget: current_data_presenter(household: current_household.reload, annual_plan: annual_plan, ensure_plan: false).budget,
          spending_report: nil
        }
        complete_message_request(message_request, response_payload)
        record_mia_operation("mia.request.completed", assistant_message: assistant_message)
        render json: response_payload, status: :created
      end

      def persist_document_evidence_state(session, document_imports, user_message, assistant_message, query_scope: nil, activate:)
        HouseholdFinance::MiaDocumentEvidenceStateUpdater.new(
          session,
          document_imports: document_imports,
          user_message: user_message,
          assistant_message: assistant_message,
          query_scope: query_scope,
          activate: activate,
          persona_context_id: current_participant_runtime.continuity_id
        ).call
      end

      def attached_document_query_scope(message, document_imports)
        return if message.blank?

        HouseholdFinance::AttachedDocumentFollowupResolver.new(
          current_household,
          message: message,
          document_imports: document_imports
        ).query_scope
      end

      def structured_session_topic?(session)
        type = session.reload.active_topic.to_h["type"].to_s
        type.present? && type != "document_evidence"
      end

      def retire_document_evidence_state(session)
        HouseholdFinance::MiaDocumentEvidenceStateUpdater.retire(
          session,
          persona_context_id: current_participant_runtime.continuity_id
        )
      end

      def reserve_message_request(session, content, attached_imports)
        request_key = params[:request_id].to_s.strip
        return [ nil, false ] if request_key.blank?

        unless request_key.match?(MiaMessageRequest::REQUEST_KEY_FORMAT) && request_key.length <= 100
          render json: { errors: [ "Mia request ID is invalid" ] }, status: :unprocessable_entity
          return [ nil, true ]
        end

        fingerprint = message_request_fingerprint(content, attached_imports)
        session.with_lock do
          existing_request = session.mia_message_requests.find_by(request_key: request_key)
          return [ existing_request, true ] if existing_request && render_existing_message_request(existing_request, fingerprint)

          message_request = session.mia_message_requests.create!(
            request_key: request_key,
            request_fingerprint: fingerprint
          )
          return [ message_request, false ]
        end
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
        message_request = session.mia_message_requests.find_by!(request_key: request_key)
        [ message_request, render_existing_message_request(message_request, fingerprint) ]
      end

      def render_preexisting_message_request(session, content, attached_imports)
        request_key = params[:request_id].to_s.strip
        return false if request_key.blank?

        unless request_key.match?(MiaMessageRequest::REQUEST_KEY_FORMAT) && request_key.length <= 100
          render json: { errors: [ "Mia request ID is invalid" ] }, status: :unprocessable_entity
          return true
        end

        existing_request = session.mia_message_requests.find_by(request_key: request_key)
        return false unless existing_request

        render_existing_message_request(existing_request, message_request_fingerprint(content, attached_imports))
      end

      def render_existing_message_request(message_request, fingerprint)
        if message_request.request_fingerprint != fingerprint
          render json: {
            error: "This Mia request ID was already used for different content. Send the edited message as a new request.",
            code: "mia_request_conflict"
          }, status: :conflict
          return true
        end

        message_request.expire_if_stale!
        if message_request.completed?
          render json: message_request.response_payload, status: message_request.response_status || :created
          return true
        end

        if message_request.failed?
          render json: message_request.response_payload, status: message_request.response_status || :service_unavailable
          return true
        end

        response.set_header("Retry-After", "1")
        render json: {
          status: "processing",
          code: "mia_request_processing",
          retry_after_ms: 500
        }, status: :accepted
        true
      end

      def message_request_fingerprint(content, attached_imports)
        payload = {
          message: content,
          year: budget_year_param,
          month: budget_month_param,
          document_import_ids: attached_imports.map(&:id).sort
        }
        if current_participant_runtime.cohort_id
          payload[:cohort_id] = current_participant_runtime.cohort_id
          payload[:cohort_release_id] = current_participant_runtime.release_id
          payload[:runtime_continuity_id] = current_participant_runtime.continuity_id
        end
        Digest::SHA256.hexdigest(payload.to_json)
      end

      def complete_message_request(message_request, response_payload)
        message_request&.complete!(response_payload.as_json, response_status: 201)
      end

      def fail_active_message_request(original_error)
        request = @active_mia_message_request
        return unless request&.reload&.processing?

        request.fail!
      rescue StandardError => failure
        Rails.logger.error("[Api::V1::MiaMessagesController] request failure recovery failed: #{failure.class}; original error: #{original_error.class}")
      end

      def attached_document_imports
        ids = requested_attachment_ids
        return [] if ids.empty?

        current_household.financial_document_imports.where(id: ids).order(:id).to_a
      end

      def requested_attachment_ids
        @requested_attachment_ids ||= raw_requested_attachment_ids.first(5)
      end

      def raw_requested_attachment_ids
        @raw_requested_attachment_ids ||= Array(params[:document_import_ids]).filter_map { |id| id.to_i if id.to_i.positive? }.uniq
      end

      def attachment_limit_exceeded?
        raw_requested_attachment_ids.length > 5
      end

      def unavailable_attachment_ids
        requested_attachment_ids - attached_document_imports.map(&:id)
      end

      def process_attached_imports(document_imports)
        document_imports.each do |document_import|
          FinancialDocumentExtractionJob.perform_later(document_import.id) if document_import.status == "uploaded"
        end
        document_imports.map(&:reload)
      end

      def persist_chat_messages(session, content, attached_imports, assistant_content, assistant_presentation: {})
        ApplicationRecord.transaction do
          user_message = session.chat_messages.create!(user_message_attributes(content, attached_imports))
          assistant_message = assistant_message_writer(session).build(
            content: assistant_content.to_s.truncate(ChatMessage::MAX_ASSISTANT_CONTENT_LENGTH, omission: "…"),
            presentation: assistant_presentation
          )
          if assistant_presentation.present? && assistant_message.invalid? && assistant_message.errors[:presentation].any?
            Rails.logger.warn("Mia presentation exceeded the persistence contract; saving the canonical plain answer")
            assistant_message.presentation = {}
          end
          assistant_message.save!
          persist_content_citations(assistant_message)
          [ user_message, assistant_message ]
        end
      end

      def persist_mia_action_draft(action_result, user_message, assistant_message)
        return unless action_result&.proposal

        action_result.proposal.create_draft!(source_chat_message: user_message, assistant_chat_message: assistant_message)
      rescue StandardError => e
        Rails.logger.error("Mia action draft could not be persisted chat_message_id=#{assistant_message&.id}: #{e.class}: #{e.message}")
        nil
      end

      def persist_content_citations(assistant_message)
        Array(@used_coach_content).each do |entry|
          assistant_message.coach_content_citations.create!(
            coach_content_item_version: entry.fetch(:item_version),
            coach_content_pack_version: entry.fetch(:pack_version),
            rank: entry.fetch(:rank),
            reason: entry.fetch(:reason)
          )
        end
      end

      def action_draft_persistence_failure_message
        "I understood the requested change, but I could not prepare the review card. Nothing changed in your approved household numbers. Please try again or use the manual controls."
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

      def attached_document_message(content, attached_imports)
        if content.present? && !HouseholdFinance::AttachedDocumentQuestionAnswerer.generic_review_request?(content)
          processing = attached_imports.select { |document_import| document_import.status.in?(%w[uploaded processing]) }
          if processing.empty?
            answer = HouseholdFinance::AttachedDocumentQuestionAnswerer.new(
              current_household,
              message: content,
              document_imports: attached_imports
            ).call
            return answer if answer.present?
          end
        end

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
            resolved_kind = metadata["routing_resolved_kind"].presence || document_import.document_kind.presence || "other"
            comparison = if metadata["routing_conflict_reason"] == "participant_signals"
              declared_kind = metadata["declared_document_kind"].presence || "another document type"
              "your message described #{resolved_kind.humanize.downcase}, selected type was #{declared_kind.humanize.downcase}"
            else
              detected_kind = metadata["routing_detected_kind"].presence || "another document type"
              "you described #{resolved_kind.humanize.downcase}, Mia detected #{detected_kind.humanize.downcase}"
            end
            "#{evidence_label(document_import)} (#{comparison})"
          end
          return "I flagged #{descriptions.to_sentence} for a routing check and preserved your description."
        end

        destinations = document_imports.flat_map { |document_import| document_routing_destinations(document_import) }.uniq
        if destinations.many?
          destination_labels = {
            "transaction_review" => "pending transaction review",
            "household_setup_review" => "household setup review",
            "private_document_review" => "private import history"
          }
          labels = destinations.map { |destination| destination_labels.fetch(destination, "private import history") }
          return "I routed the uploads to #{labels.to_sentence}."
        end
        return "I routed the upload#{'s' if document_imports.many?} to household setup review." if destinations == [ "household_setup_review" ]
        return "I saved the upload#{'s' if document_imports.many?} in private import history for review." if destinations == [ "private_document_review" ]

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

        items = document_import.items.where(ignored: false, applied_at: nil).order(:id).to_a
        if items.any?
          labels = items.first(3).map(&:label).to_sentence
          return "#{route_line} I found #{items.length} budget/profile setup value#{'s' unless items.length == 1} for review: #{labels}. You stay the CFO here: open Review imports to approve or adjust them before anything updates the household plan."
        end

        if document_import_has_results?(document_import)
          return "#{route_line} All extracted results are resolved, so nothing from this upload is waiting for approval."
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

        actual_destinations = document_routing_destinations(document_import)
        destination = actual_destinations.map { |value| document_routing_destination_label(value) }.to_sentence
        declared_kind = metadata["declared_document_kind"].presence
        planned_destination = metadata["routing_destination"].presence

        if actual_destinations == [ "private_document_review" ] && document_import_has_results?(document_import)
          return "I recognized this as #{resolved_kind.humanize.downcase} and kept the resolved results in #{destination}."
        end

        if declared_kind.present? && planned_destination.present? && actual_destinations != [ planned_destination ]
          return "You selected this as #{declared_kind.humanize.downcase}. I checked the file and routed the reviewable results I actually found to #{destination}."
        end

        "I recognized this as #{resolved_kind.humanize.downcase} and routed it to #{destination}."
      end

      def document_routing_destinations(document_import)
        destinations = []
        has_transaction_results = document_import.respond_to?(:transaction_drafts) && document_import.transaction_drafts.exists?
        has_item_results = document_import.respond_to?(:items) && document_import.items.exists?
        if has_transaction_results && document_import.transaction_drafts.pending.exists?
          destinations << "transaction_review"
        end
        if has_item_results && document_import.items.where(ignored: false, applied_at: nil).exists?
          destinations << "household_setup_review"
        end
        return destinations if destinations.any?
        return [ "private_document_review" ] if has_transaction_results || has_item_results

        [ document_import.metadata.to_h["routing_destination"].presence ||
          FinancialDocuments::RoutingDecision::DESTINATIONS.fetch(document_import.document_kind, "private_document_review") ]
      end

      def document_import_has_results?(document_import)
        (document_import.respond_to?(:transaction_drafts) && document_import.transaction_drafts.exists?) ||
          (document_import.respond_to?(:items) && document_import.items.exists?)
      end

      def document_routing_destination_label(destination)
        case destination
        when "transaction_review" then "pending transaction review"
        when "household_setup_review" then "household setup review"
        else "private import history"
        end
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

      def route_model_intent(intent_result, content:, conversation_context:, annual_budget_manager:, annual_plan:)
        resolved_content = intent_result.resolved_message.presence || content
        followup = HouseholdFinance::ConversationFollowupResolver.new(
          content,
          conversation_context: conversation_context
        ).call
        read_only_plan = read_only_answer_plan(intent_result, content)
        read_only_result = if read_only_plan
          HouseholdFinance::MiaReadOnlyPlanAnswerer.new(
            current_household,
            plan: read_only_plan,
            annual_budget_manager: annual_budget_manager,
            annual_plan: annual_plan,
            reference_month: budget_month_param,
            conversation_messages: @mia_conversation_messages
          ).call
        end
        annual_plan = read_only_result.annual_plan if read_only_result
        direct_answer = read_only_result&.answer
        if direct_answer.blank? && intent_result.clarification?
          direct_answer = coaching_guardrail_answer(
            resolved_content,
            annual_budget_manager: annual_budget_manager
          ).presence || clarification_answer(intent_result)
        end
        pending_draft_answer = pending_guardrail_answer(content)
        action_result = nil
        coach_answer = nil
        transaction_lookup_answer = nil
        spending_report = nil
        budget_answer = nil
        transaction_draft = nil
        transaction_draft_answer = nil

        unless direct_answer || pending_draft_answer
          if HouseholdFinance::TransactionLookupAnswerer.bank_activity_question?(content)
            transaction_lookup_answer = HouseholdFinance::TransactionLookupAnswerer.new(current_household, content).call
          end

          # A model can label a repeated, fully specified lookup as "recall" because it
          # recognizes the topic in history. Re-run explicit current-turn questions
          # against Rails-owned transaction truth instead of replaying a stale answer.
          if transaction_lookup_answer.nil? && intent_result.intent == "recall"
            transaction_lookup_answer = HouseholdFinance::TransactionLookupAnswerer.new(current_household, content).call
          end

          if transaction_lookup_answer.nil? && intent_result.intent == "recall" && followup.follow_up?
            direct_answer = followup.direct_answer
          end

          case transaction_lookup_answer ? nil : intent_result.intent
          when "action_plan"
            if intent_result.actionable?
              action_result = HouseholdFinance::MiaActionDraftBuilder.new(
                current_household,
                user: current_user,
                annual_budget_manager: annual_budget_manager,
                selected_month: budget_month_param,
                raw_input: content,
                command: { type: "compound_action_plan", actions: intent_result.write_plan.to_h[:actions] }
              ).call
            else
              direct_answer = clarification_answer(intent_result)
            end
          when "budget_action", "household_action", "income_action", "debt_action", "asset_action", "goal_action"
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
            coach_answerer = HouseholdFinance::MiaCoachAnswerer.new(
              current_household,
              resolved_content,
              annual_budget_manager: budget_manager,
              reference_month: budget_month_param,
              conversation_messages: @mia_conversation_messages
            )
            coach_answer = coach_answerer.call
            annual_plan = coach_answerer.prepared_annual_plan || annual_plan
            budget_answer = HouseholdFinance::BudgetQuestionAnswerer.new(resolved_content, annual_plan: annual_plan).call if coach_answer.blank?
          when "spending_report"
            spending_report = spending_report_for(resolved_content)
          when "transaction_report"
            if intent_result.transaction_report_action? && intent_result.actionable?
              creation = HouseholdFinance::MiaTransactionDraftCreator.new(
                current_household,
                command: intent_result.action,
                raw_input: content,
                user: current_user,
                idempotency_key: mia_transaction_idempotency_key("create")
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
                raw_input: content,
                user: current_user,
                idempotency_key: mia_transaction_idempotency_key("legacy-create")
              ).call
            end
            annual_plan = annual_plan_for_transaction_draft(transaction_draft, annual_budget_manager) if transaction_draft
          when "transaction_draft_action"
            if intent_result.actionable?
              if intent_result.action.to_h[:type] == "ignore_transaction_drafts"
                ignored = HouseholdFinance::MiaTransactionDraftIgnorer.new(
                  current_household,
                  command: intent_result.action,
                  raw_input: content,
                  user: current_user,
                  idempotency_key: mia_transaction_idempotency_key("ignore")
                ).call
                direct_answer = ignored.response
                annual_plan = annual_budget_manager.plan_data if ignored.success?
              else
                draft_edit = HouseholdFinance::MiaTransactionDraftEditor.new(
                  current_household,
                  command: intent_result.action,
                  user: current_user,
                  idempotency_key: mia_transaction_idempotency_key("update", intent_result.action.to_h[:draft_id])
                ).call
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
              reference_month: budget_month_param,
              conversation_messages: @mia_conversation_messages
            )
            coach_answer = coach_answerer.call
            annual_plan = coach_answerer.prepared_annual_plan || annual_plan
          end
        end

        {
          routed_content: resolved_content,
          followup: followup,
          direct_answer: direct_answer,
          presentation: read_only_result&.presentation,
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

      def read_only_answer_plan(intent_result, content)
        return intent_result.read_only_plan if intent_result.read_only_plan?
        return unless ::Mia::FinancialReadOnlyRequest.matches?(content)

        kind = intent_result.intent.in?(HouseholdFinance::MiaIntentResolver::READ_ONLY_KINDS) ? intent_result.intent : "coaching"
        question = intent_result.resolved_message.presence || content
        question = content if content.match?(HouseholdFinance::MiaCoachAnswerer::READ_ONLY_AMOUNT_EDIT_PATTERN)
        {
          title: "Read-only household question",
          items: [ {
            kind: kind, source_text: content, resolved_question: question,
            basis: "approved", scenario_type: "none", scenario_label: "", amount: "", effective_on: ""
          } ]
        }
      end

      def coaching_guardrail_answer(content, annual_budget_manager:)
        HouseholdFinance::MiaCoachAnswerer.new(
          current_household,
          content,
          annual_budget_manager: annual_budget_manager,
          reference_month: budget_month_param,
          conversation_messages: @mia_conversation_messages
        ).guardrail_answer
      end

      def route_legacy_message(content, conversation_context:, annual_budget_manager:)
        followup = HouseholdFinance::ConversationFollowupResolver.new(content, conversation_context: conversation_context).call
        if HouseholdFinance::MiaTransactionDraftIgnorer.explicit_all_request?(content)
          ignored = HouseholdFinance::MiaTransactionDraftIgnorer.new(
            current_household,
            command: { type: "ignore_transaction_drafts", all_pending: true },
            raw_input: content,
            user: current_user,
            idempotency_key: mia_transaction_idempotency_key("ignore-all")
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
        transaction_lookup_answer = if pending_draft_answer.nil? && HouseholdFinance::TransactionLookupAnswerer.bank_activity_question?(routed_content)
          HouseholdFinance::TransactionLookupAnswerer.new(current_household, routed_content).call
        end
        action_result = (pending_draft_answer || transaction_lookup_answer) ? nil : HouseholdFinance::MiaActionDraftBuilder.new(
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
          reference_month: budget_month_param,
          conversation_messages: @mia_conversation_messages
        )
        coach_answer = (pending_draft_answer || transaction_lookup_answer || action_result) ? nil : followup.direct_answer || coach_answerer.call
        transaction_lookup_answer ||= (coach_answer || pending_draft_answer || action_result) ? nil : HouseholdFinance::TransactionLookupAnswerer.new(current_household, routed_content).call
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
            raw_input: content,
            user: current_user,
            idempotency_key: mia_transaction_idempotency_key("legacy-create")
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
            command: { draft_id: pending.first.id, occurred_on: Date.current.prev_day.iso8601 },
            user: current_user,
            idempotency_key: mia_transaction_idempotency_key("legacy-update", pending.first.id)
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
          schema_version: intent_result.action_plan? ? 5 : intent_result.read_only_plan? ? 3 : 2,
          type: topic[:type],
          title: topic[:title],
          subject: topic[:subject],
          intent: intent_result.intent,
          confidence: intent_result.confidence,
          resolved_message: intent_result.resolved_message,
          read_only_plan: intent_result.read_only_plan? ? intent_result.read_only_plan : nil,
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
          draft_answer = transaction_draft_answer.presence || drafted_transaction_message(transaction_draft, annual_plan)
          kind = transaction_draft_answer.present? ? "transaction_draft_update" : "transaction_draft"
          write_state = transaction_draft_answer.present? ? "draft_updated" : "pending_review"
          return narrate_structured_answer(content, history, conversation_context, kind: kind, fallback_response: draft_answer, annual_plan: annual_plan, transaction_draft: transaction_draft, write_state: write_state, selected_month: transaction_draft.occurred_on.month)
        end

        context = HouseholdFinance::MiaContextBuilder.new(
          current_household,
          annual_plan: annual_plan,
          reference_month: budget_month_param,
          conversation_context: conversation_context,
          experience_capabilities: current_experience_capabilities
        ).call
        response_history = conversation_resolution&.dig(:intent) == "recall" ? [] : history
        responder = ::Demo::MiaResponder.new(persona: current_persona, approved_content: @approved_coach_content)
        response = responder.call(
          content,
          history: response_history,
          context: context,
          draft_capable: false,
          conversation_resolution: conversation_resolution
        )
        @used_coach_content = responder.respond_to?(:supplied_content_context) ? responder.supplied_content_context : []
        response
      end

      def apply_persona_capability_boundary(content, direct_answer:, presentation:)
        return [ direct_answer, presentation ] unless Mia::Capabilities.persona_configuration_request?(content)

        apply_response_boundary(
          direct_answer: direct_answer,
          presentation: presentation,
          boundary: Mia::Capabilities.persona_configuration_answer
        )
      end

      def append_persona_capability_boundary(content, assistant_content)
        return assistant_content unless Mia::Capabilities.persona_configuration_request?(content)

        append_response_boundary(assistant_content, boundary: Mia::Capabilities.persona_configuration_answer)
      end

      def apply_prompt_injection_boundary(content, direct_answer:, presentation:)
        return [ direct_answer, presentation ] unless HouseholdFinance::MiaCoachAnswerer.prompt_injection?(content)

        apply_response_boundary(
          direct_answer: direct_answer,
          presentation: presentation,
          boundary: HouseholdFinance::MiaCoachAnswerer.prompt_injection_boundary
        )
      end

      def append_prompt_injection_boundary(content, assistant_content)
        return assistant_content unless HouseholdFinance::MiaCoachAnswerer.prompt_injection?(content)

        append_response_boundary(assistant_content, boundary: HouseholdFinance::MiaCoachAnswerer.prompt_injection_boundary)
      end

      def apply_response_boundary(direct_answer:, presentation:, boundary:)
        return [ direct_answer, presentation ] if direct_answer.blank? && presentation.blank?

        bounded_presentation = presentation.deep_dup
        if bounded_presentation.present?
          lead_key = bounded_presentation.key?(:lead) ? :lead : "lead"
          existing_lead = bounded_presentation[lead_key].to_s
          available_lead_length = [ 500 - boundary.length - 1, 0 ].max
          bounded_lead = existing_lead.truncate(available_lead_length, omission: "…")
          bounded_presentation[lead_key] = [ bounded_lead, boundary ].compact_blank.join(" ")
        end
        [ direct_answer, bounded_presentation ]
      end

      def append_response_boundary(assistant_content, boundary:)
        return assistant_content if assistant_content.to_s.include?(boundary)

        [ assistant_content, boundary ].compact_blank.join(" ")
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

        narrator = HouseholdFinance::MiaNarrator.new(
          user_message: content,
          history: history,
          answer_packet: answer_packet,
          persona: current_persona,
          approved_content: @approved_coach_content
        )
        response = narrator.call
        @used_coach_content = narrator.respond_to?(:supplied_content_context) ? narrator.supplied_content_context : []
        response
      end

      def assistant_message_writer(session)
        ::Mia::AssistantMessageWriter.new(
          session: session,
          persona: current_persona,
          participant_runtime: current_participant_runtime
        )
      end

      def user_message_attributes(content, attached_imports)
        {
          role: "user",
          content: content,
          attachments: attached_imports.map { |document_import| serialize_attachment(document_import) },
          cohort_id: current_participant_runtime.cohort_id,
          cohort_release_id: current_participant_runtime.release_id
        }
      end

      def drafted_transaction_message(draft, annual_plan)
        category = drafted_transaction_category_label(draft)
        impact = drafted_transaction_impact_line(draft, annual_plan)
        "I drafted this for review: #{draft.merchant} for #{money(draft.total_amount_cents)} in #{category}. #{impact} Confirm it only if the merchant, amount, and category are right. Month-to-date actuals will not change until you approve it."
      end

      def drafted_transaction_category_label(draft)
        return draft.budget_category.name if draft.budget_category

        categories = draft.transaction_draft_splits.filter_map { |split| split.budget_category&.name || split.category_name }.uniq
        return categories.first if categories.one?
        return "#{categories.length} categories" if categories.many?

        "Uncategorized"
      end

      def drafted_transaction_impact_line(draft, annual_plan)
        impacts = HouseholdFinance::TransactionDraftBudgetImpact.new(annual_plan: annual_plan, draft: draft).call
        known = impacts.select { |impact| impact[:status] != "needs_category" }
        return "Choose a category in the draft to see its budget impact." if known.empty?

        impact = known.min_by { |candidate| candidate.fetch(:remaining_if_approved_cents) }
        remaining_cents = impact.fetch(:remaining_if_approved_cents)
        outcome = if remaining_cents.negative?
          "would be #{money(remaining_cents.abs)} over its #{money(impact.fetch(:planned_cents))} plan"
        else
          "would have #{money(remaining_cents)} left in its #{money(impact.fetch(:planned_cents))} plan"
        end
        line = "If approved, #{draft.occurred_on.strftime('%B')}'s #{impact.fetch(:category_name)} category #{outcome}."
        line += " The review card shows all #{known.length} category impacts." if known.length > 1
        line
      end

      def money(cents)
        ActionController::Base.helpers.number_to_currency(
          HouseholdFinance::Money.dollars(cents),
          precision: cents.to_i % 100 == 0 ? 0 : 2
        )
      end

      def mia_transaction_idempotency_key(action, draft_id = nil)
        request_key = @active_mia_message_request&.request_key.presence || request.request_id
        [ "mia-transaction", current_user.id, current_chat_session.id, request_key, action, draft_id ].compact.join(":").first(200)
      end

      def serialize_mia_action_draft(draft, selected_item_ids: nil)
        HouseholdFinance::MiaActionDraftPresenter.new(draft).call.tap do |payload|
          payload[:suggested_selected_item_ids] = Array(selected_item_ids) if selected_item_ids.present?
        end
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
              confidence: split.confidence,
              metadata: split.metadata || {}
            }
          end,
          matches: [],
          matched_transaction_id: draft.matched_transaction_id,
          summary: "#{draft.merchant} — #{ActionController::Base.helpers.number_to_currency(HouseholdFinance::Money.dollars(draft.total_amount_cents), precision: 2)}"
        }
      end

      def update_conversation_state(session, intent_result:, user_message:, assistant_message:, mia_action_draft:, transaction_draft:,
        persona_context_id:)
        HouseholdFinance::MiaConversationStateUpdater.new(
          session,
          intent_result: intent_result,
          user_message: user_message,
          assistant_message: assistant_message,
          mia_action_draft: mia_action_draft,
          transaction_draft: transaction_draft,
          persona_context_id: persona_context_id
        ).call
      rescue StandardError => e
        Rails.logger.warn("Mia conversation state could not be saved chat_session_id=#{session&.id}: #{e.class}: #{e.message}")
        false
      end

      def compact_conversation(session, user_message, assistant_message, follow_up: false, persona_context_id:)
        HouseholdFinance::ConversationCompactor.new(
          session,
          user_message: user_message,
          assistant_message: assistant_message,
          follow_up: follow_up,
          persona_context_id: persona_context_id
        ).call
      rescue StandardError => e
        Rails.logger.warn("Conversation compaction could not be scheduled chat_session_id=#{session&.id}: #{e.class}: #{e.message}")
        false
      end

      def current_chat_session
        existing_session = current_household.chat_sessions.find_by(user: current_user)
        return existing_session if existing_session

        now = Time.current
        ChatSession.insert_all(
          [ {
            household_id: current_household.id,
            user_id: current_user.id,
            title: "Ask Mia",
            created_at: now,
            updated_at: now
          } ],
          unique_by: :index_chat_sessions_on_household_id_and_user_id
        )
        current_household.chat_sessions.find_by!(user: current_user)
      end

      def record_mia_operation(event_type, assistant_message: nil, attached_imports: [], transaction_draft: nil, mia_action_draft: nil, error_code: nil)
        started_at = @mia_request_started_at || Process.clock_gettime(Process::CLOCK_MONOTONIC)
        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
        current_household.household_audit_events.create!(
          user: current_user,
          actor_type: "system",
          event_type: event_type,
          occurred_at: Time.current,
          metadata: {
            duration_ms: duration_ms,
            assistant_characters: assistant_message&.content.to_s.length,
            attachment_count: Array(attached_imports).length,
            created_transaction_draft: transaction_draft.present?,
            created_action_draft: mia_action_draft.present?,
            error_code: error_code
          }.compact
        )
      rescue StandardError => telemetry_error
        Rails.logger.warn("Mia operation telemetry could not be saved: #{telemetry_error.class}")
      end
    end
  end
end
