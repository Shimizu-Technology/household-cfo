require "test_helper"

class ApiV1MiaActionDraftsControllerTest < ActionDispatch::IntegrationTest
  test "mia drafts budget allocation edits without mutating the official budget until apply" do
    user = create_user(email: "mia-action-apply@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    category = HouseholdFinance::AnnualBudgetManager.new(household).create_category!(name: "Groceries", stack_key: "discretionary", monthly_amount: 500)

    post "/api/v1/mia/messages",
      params: { message: "Set Groceries budget to $800 per month" },
      headers: auth_headers(user),
      as: :json

    assert_response :created
    body = JSON.parse(response.body)
    action_draft_payload = body.fetch("mia_action_draft")
    assert_equal "pending", action_draft_payload.fetch("status")
    assert_equal "update_allocation", action_draft_payload.fetch("items").first.fetch("action_type")
    assert_includes body.fetch("assistant_message").fetch("content"), "Nothing changed in the official budget yet"
    assert_equal 1, body.fetch("budget").fetch("annual_plan").fetch("pending_mia_action_drafts").length
    assert_equal "mia_action_draft.proposed", HouseholdAuditEvent.find_by!(auditable_type: "MiaActionDraft", auditable_id: action_draft_payload.fetch("id")).event_type
    assert_equal [ 50_000 ], planned_amounts_for(category)

    assert_no_difference("HouseholdTransaction.count") do
      assert_difference("HouseholdAuditEvent.count", 1) do
        post "/api/v1/mia_action_drafts/#{action_draft_payload.fetch("id")}/apply",
          headers: auth_headers(user),
          as: :json
      end
    end

    assert_response :success
    apply_body = JSON.parse(response.body)
    assert_equal "applied", MiaActionDraft.find(action_draft_payload.fetch("id")).status
    assert_equal [ 80_000 ], planned_amounts_for(category)
    assert_equal [ "manual" ], allocation_sources_for(category)
    assert_empty apply_body.fetch("workspace").fetch("budget").fetch("annual_plan").fetch("pending_mia_action_drafts")
    assert_includes apply_body.fetch("workspace").fetch("mia").fetch("messages").last.fetch("content"), "Applied Mia’s budget edit"
  end

  test "malformed persisted action payload fails safely without changing the budget" do
    user = create_user(email: "mia-action-incomplete-payload@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    category = HouseholdFinance::AnnualBudgetManager.new(household).create_category!(name: "Groceries", stack_key: "discretionary", monthly_amount: 500)

    post "/api/v1/mia/messages",
      params: { message: "Set Groceries budget to $800 per month" },
      headers: auth_headers(user),
      as: :json

    assert_response :created
    draft = MiaActionDraft.find(JSON.parse(response.body).dig("mia_action_draft", "id"))
    draft.mia_action_items.first.update_column(:payload, {})

    assert_no_difference("HouseholdAuditEvent.count") do
      post "/api/v1/mia_action_drafts/#{draft.id}/apply",
        headers: auth_headers(user),
        as: :json
    end

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body).fetch("errors"), HouseholdFinance::MiaActionDraftApplier::INCOMPLETE_DRAFT_MESSAGE
    assert_equal "pending", draft.reload.status
    assert_equal [ 50_000 ], planned_amounts_for(category)
  end

  test "model resolved budget intent creates a Rails validated review card and structured conversation thread" do
    user = create_user(email: "mia-model-intent-action@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    fixed = HouseholdFinance::AnnualBudgetManager.new(household).create_category!(name: "Fixed essentials", stack_key: "non_discretionary", monthly_amount: 4_000)
    intent = HouseholdFinance::MiaIntentResolver::Result.new(
      intent: "budget_action",
      confidence: 0.98,
      continuation: true,
      resolved_message: "Set Fixed essentials to $3,000 for July #{Date.current.year}",
      needs_clarification: false,
      clarification: "",
      topic: { type: "budget_edit", title: "July Fixed essentials edit", subject: "Fixed essentials" },
      action: {
        type: "set_allocation",
        category_id: fixed.id,
        category_name: "Fixed essentials",
        target_category_id: 0,
        target_category_name: "",
        new_name: "",
        stack_key: "",
        amount: "3000.00",
        months: [ 7 ],
        year: Date.current.year,
        draft_id: 0
      },
      source: "model"
    )
    resolver = Object.new
    resolver.define_singleton_method(:call) { intent }

    with_intent_resolver(resolver) do
      post "/api/v1/mia/messages",
        params: { year: Date.current.year, month: 7, message: "Yeah, please do that" },
        headers: auth_headers(user),
        as: :json
    end

    assert_response :created
    body = JSON.parse(response.body)
    draft = body.fetch("mia_action_draft")
    assert_equal "pending", draft.fetch("status")
    change = draft.fetch("items").first.fetch("payload").fetch("changes").first
    assert_equal 7, change.fetch("month")
    assert_equal 400_000, change.fetch("before_cents")
    assert_equal 300_000, change.fetch("after_cents")
    assert_equal 400_000, planned_amount_for_month(fixed, 7)

    topic = household.chat_sessions.find_by!(user: user).reload.active_topic
    assert_equal 2, topic.fetch("schema_version")
    assert_equal "budget_edit", topic.fetch("type")
    assert_equal "Fixed essentials", topic.fetch("subject")
    assert_equal "pending_review", topic.fetch("status")
    assert_equal draft.fetch("id"), topic.fetch("mia_action_draft_id")
    assert_equal "set_allocation", topic.fetch("action").fetch("type")

    post "/api/v1/mia_action_drafts/#{draft.fetch('id')}/apply",
      headers: auth_headers(user),
      as: :json

    assert_response :success
    session = household.chat_sessions.find_by!(user: user).reload
    assert_equal "applied", session.active_topic.fetch("status")
    assert_includes session.rolling_summary, "applied"
    assert_equal 300_000, planned_amount_for_month(fixed, 7)
  end

  test "model resolved recall composes from verified resolution instead of rejected assistant history" do
    user = create_user(email: "mia-model-intent-recall@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    fixed = HouseholdFinance::AnnualBudgetManager.new(household).create_category!(name: "Fixed essentials", stack_key: "non_discretionary", monthly_amount: 4_000)
    session = household.chat_sessions.create!(user: user, title: "Ask Mia")
    session.chat_messages.create!(role: "user", content: "For July can you lower that down to 3000?")
    session.chat_messages.create!(role: "assistant", content: "Your next move is to send the next three due bills.")
    intent = HouseholdFinance::MiaIntentResolver::Result.new(
      intent: "recall",
      confidence: 0.99,
      continuation: true,
      resolved_message: "Recall setting Fixed essentials to $3,000 for July #{Date.current.year}",
      needs_clarification: false,
      clarification: "",
      topic: { type: "budget_action", title: "Lowering Fixed essentials category", subject: "Fixed essentials" },
      action: {
        type: "set_allocation",
        category_id: fixed.id,
        category_name: "Fixed essentials",
        target_category_id: 0,
        target_category_name: "",
        new_name: "",
        stack_key: "non_discretionary",
        amount: "3000",
        months: [ 7 ],
        year: Date.current.year,
        draft_id: 0
      },
      source: "model"
    )
    resolver = Object.new
    resolver.define_singleton_method(:call) { intent }
    captured = {}
    responder = Object.new
    responder.define_singleton_method(:call) do |_message, history:, context:, draft_capable:, conversation_resolution:|
      captured.merge!(history: history, context: context, draft_capable: draft_capable, resolution: conversation_resolution)
      "We were discussing setting Fixed essentials to $3,000 for July. Nothing changed yet."
    end

    with_intent_resolver(resolver) do
      with_mia_responder(responder) do
        post "/api/v1/mia/messages",
          params: { year: Date.current.year, month: 7, message: "What were we just talking about?" },
          headers: auth_headers(user),
          as: :json
      end
    end

    assert_response :created
    assert_empty captured.fetch(:history)
    assert_equal "recall", captured.dig(:resolution, :intent)
    assert_equal "set_allocation", captured.dig(:resolution, :action, :type)
    assert_equal fixed.id, captured.dig(:resolution, :action, :category_id)
    assert_includes JSON.parse(response.body).fetch("assistant_message").fetch("content"), "Fixed essentials"
  end

  test "model resolved pending review intent returns the existing card without duplicating it" do
    user = create_user(email: "mia-model-intent-existing-card@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    fixed = HouseholdFinance::AnnualBudgetManager.new(household).create_category!(name: "Fixed essentials", stack_key: "non_discretionary", monthly_amount: 4_000)
    initial_result = HouseholdFinance::MiaActionDraftBuilder.new(
      household,
      user: user,
      annual_budget_manager: HouseholdFinance::AnnualBudgetManager.new(household),
      selected_month: 7,
      raw_input: "Set Fixed essentials to $3,000 in July",
      command: {
        type: "set_allocation",
        category_id: fixed.id,
        category_name: "Fixed essentials",
        amount: "3000",
        months: [ 7 ],
        year: Date.current.year
      }
    ).call
    session = household.chat_sessions.create!(user: user, title: "Ask Mia")
    source = session.chat_messages.create!(role: "user", content: "Set Fixed essentials to $3,000 in July")
    assistant = session.chat_messages.create!(role: "assistant", content: initial_result.response)
    existing = initial_result.proposal.create_draft!(source_chat_message: source, assistant_chat_message: assistant)
    intent = HouseholdFinance::MiaIntentResolver::Result.new(
      intent: "budget_action",
      confidence: 0.99,
      continuation: true,
      resolved_message: "Review the pending Fixed essentials budget edit",
      needs_clarification: false,
      clarification: "",
      topic: { type: "budget_edit", title: "July Fixed essentials edit", subject: "Fixed essentials" },
      action: {
        type: "review_pending_action",
        category_id: fixed.id,
        category_name: "Fixed essentials",
        draft_id: existing.id,
        months: [ 7 ],
        year: Date.current.year
      },
      source: "model"
    )
    resolver = Object.new
    resolver.define_singleton_method(:call) { intent }

    assert_no_difference("MiaActionDraft.count") do
      with_intent_resolver(resolver) do
        post "/api/v1/mia/messages",
          params: { year: Date.current.year, month: 7, message: "Yeah, please do that" },
          headers: auth_headers(user),
          as: :json
      end
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal existing.id, body.fetch("mia_action_draft").fetch("id")
    assert_includes body.fetch("assistant_message").fetch("content"), "review card is ready"
  end

  test "mia does not surface a no-op allocation draft" do
    user = create_user(email: "mia-action-no-op@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    category = HouseholdFinance::AnnualBudgetManager.new(household).create_category!(name: "Groceries", stack_key: "discretionary", monthly_amount: 500)

    assert_no_difference("MiaActionDraft.count") do
      post "/api/v1/mia/messages",
        params: { message: "Set Groceries budget to $500 per month" },
        headers: auth_headers(user),
        as: :json
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_nil body.fetch("mia_action_draft")
    assert_includes body.fetch("assistant_message").fetch("content"), "already $500"
    assert_includes body.fetch("assistant_message").fetch("content"), "nothing would change"
    assert_equal [ 50_000 ], planned_amounts_for(category)
  end

  test "explicit month wins over per-month wording in allocation drafts" do
    user = create_user(email: "mia-action-explicit-month@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    category = HouseholdFinance::AnnualBudgetManager.new(household).create_category!(name: "Groceries", stack_key: "discretionary", monthly_amount: 500)

    post "/api/v1/mia/messages",
      params: { message: "Set Groceries budget to $800 per month in July" },
      headers: auth_headers(user),
      as: :json

    assert_response :created
    draft = JSON.parse(response.body).fetch("mia_action_draft")
    changes = draft.fetch("items").first.fetch("payload").fetch("changes")
    assert_equal 1, changes.length
    assert_equal 7, changes.first.fetch("month")

    post "/api/v1/mia_action_drafts/#{draft.fetch("id")}/apply",
      headers: auth_headers(user),
      as: :json

    assert_response :success
    assert_equal 80_000, planned_amount_for_month(category, 7)
    assert_equal 50_000, planned_amount_for_month(category, 6)
    assert_equal 50_000, planned_amount_for_month(category, 8)
  end

  test "mia resolves contextual budget category when user says lower that after largest category answer" do
    user = create_user(email: "mia-action-contextual-category@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    manager = HouseholdFinance::AnnualBudgetManager.new(household)
    fixed = manager.create_category!(name: "Fixed essentials", stack_key: "non_discretionary", monthly_amount: 4_000)
    manager.create_category!(name: "Rent", stack_key: "non_discretionary", monthly_amount: 1_800)
    manager.create_category!(name: "Dining Out", stack_key: "discretionary", monthly_amount: 300)

    post "/api/v1/mia/messages",
      params: { year: Date.current.year, month: 7, message: "What's our largest category?" },
      headers: auth_headers(user),
      as: :json

    assert_response :created
    first_body = JSON.parse(response.body)
    assert_includes first_body.fetch("assistant_message").fetch("content"), "Fixed essentials"
    assert_equal "Fixed essentials", household.chat_sessions.find_by!(user: user).reload.active_topic.fetch("subject")

    post "/api/v1/mia/messages",
      params: { year: Date.current.year, month: 7, message: "For July can you lower that down to 3000?" },
      headers: auth_headers(user),
      as: :json

    assert_response :created
    body = JSON.parse(response.body)
    action_draft_payload = body.fetch("mia_action_draft")
    assert_equal "pending", action_draft_payload.fetch("status")
    assert_includes body.fetch("assistant_message").fetch("content"), "Fixed essentials"
    item = action_draft_payload.fetch("items").first
    assert_equal "update_allocation", item.fetch("action_type")
    assert_includes item.fetch("label"), "Fixed essentials"
    changes = item.fetch("payload").fetch("changes")
    assert_equal 1, changes.length
    assert_equal 7, changes.first.fetch("month")
    assert_equal 400_000, changes.first.fetch("before_cents")
    assert_equal 300_000, changes.first.fetch("after_cents")
    assert_equal 400_000, planned_amount_for_month(fixed, 7)
  end

  test "mia points back to an existing pending budget review card instead of drafting a duplicate" do
    user = create_user(email: "mia-action-no-duplicate-after-recall@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    manager = HouseholdFinance::AnnualBudgetManager.new(household)
    manager.create_category!(name: "Fixed essentials", stack_key: "non_discretionary", monthly_amount: 4_000)
    manager.create_category!(name: "Dining Out", stack_key: "discretionary", monthly_amount: 300)

    post "/api/v1/mia/messages",
      params: { year: Date.current.year, month: 7, message: "What's our largest category?" },
      headers: auth_headers(user),
      as: :json
    assert_response :created

    post "/api/v1/mia/messages",
      params: { year: Date.current.year, month: 7, message: "For July can you lower that down to 3000?" },
      headers: auth_headers(user),
      as: :json
    assert_response :created
    first_draft_id = JSON.parse(response.body).fetch("mia_action_draft").fetch("id")

    post "/api/v1/mia/messages",
      params: { year: Date.current.year, month: 7, message: "What were we just talking about?" },
      headers: auth_headers(user),
      as: :json
    assert_response :created
    assert_includes JSON.parse(response.body).fetch("assistant_message").fetch("content"), "Fixed essentials"

    assert_no_difference("MiaActionDraft.count") do
      post "/api/v1/mia/messages",
        params: { year: Date.current.year, month: 7, message: "Yeah, please do that" },
        headers: auth_headers(user),
        as: :json
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal first_draft_id, body.fetch("mia_action_draft").fetch("id")
    assert_includes body.fetch("assistant_message").fetch("content"), "review card is ready"
    assert_equal [ first_draft_id ], body.fetch("budget").fetch("annual_plan").fetch("pending_mia_action_drafts").map { |draft| draft.fetch("id") }
  end

  test "deterministic fallback asks for an exact restatement instead of guessing from an older topic" do
    user = create_user(email: "mia-action-recalled-topic@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    manager = HouseholdFinance::AnnualBudgetManager.new(household)
    fixed = manager.create_category!(name: "Fixed essentials", stack_key: "non_discretionary", monthly_amount: 4_000)
    manager.create_category!(name: "Rent", stack_key: "non_discretionary", monthly_amount: 1_800)
    manager.create_category!(name: "Dining Out", stack_key: "discretionary", monthly_amount: 300)
    budget_topic = {
      id: SecureRandom.uuid,
      type: "budget_report",
      title: "Budget or spending report",
      subject: "Fixed essentials",
      status: "open",
      latest_user_context: "For July can you lower that down to 3000?",
      latest_mia_summary: "I can draft setting Fixed essentials to $3,000 for July after you confirm the category.",
      next_move: "Draft the Fixed essentials July edit for review.",
      updated_at: Time.current.iso8601
    }
    readiness_topic = {
      id: SecureRandom.uuid,
      type: "readiness_plan",
      title: "Readiness plan",
      subject: "red/yellow/green plan",
      status: "open",
      latest_user_context: "How do I get out of the red?",
      latest_mia_summary: "Readiness is Red.",
      next_move: "Send the next three due bills.",
      updated_at: 5.minutes.ago.iso8601
    }
    household.chat_sessions.create!(
      user: user,
      title: "Ask Mia",
      active_topic: readiness_topic,
      open_topics: [ budget_topic, readiness_topic ],
      rolling_summary: "Open conversation topics: budget action for Fixed essentials and readiness plan."
    )

    post "/api/v1/mia/messages",
      params: { year: Date.current.year, month: 7, message: "What were we just talking about?" },
      headers: auth_headers(user),
      as: :json

    assert_response :created
    recall_body = JSON.parse(response.body)
    assert_includes recall_body.fetch("assistant_message").fetch("content"), "Fixed essentials"
    session = household.chat_sessions.find_by!(user: user).reload
    assert_equal "budget_report", session.active_topic.fetch("type")
    assert_equal "Fixed essentials", session.active_topic.fetch("subject")
    assert_equal "For July can you lower that down to 3000?", session.active_topic.fetch("latest_user_context")

    post "/api/v1/mia/messages",
      params: { year: Date.current.year, month: 7, message: "Yeah, please do that" },
      headers: auth_headers(user),
      as: :json

    assert_response :created
    body = JSON.parse(response.body)
    assert_nil body.fetch("mia_action_draft")
    assert_includes body.fetch("assistant_message").fetch("content"), "do not want to guess"
    assert_includes body.fetch("assistant_message").fetch("content"), "restate the category, amount, and month"
    refute_includes body.fetch("assistant_message").fetch("content"), "readiness"
    assert_equal 400_000, planned_amount_for_month(fixed, 7)
  end

  test "mia chat persists messages even when action draft persistence raises a non-Active Record error" do
    user = create_user(email: "mia-action-persistence-failure@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    HouseholdFinance::AnnualBudgetManager.new(household).create_category!(name: "Groceries", stack_key: "discretionary", monthly_amount: 500)

    original_create_draft = HouseholdFinance::MiaActionDraftBuilder::Proposal.instance_method(:create_draft!)
    begin
      HouseholdFinance::MiaActionDraftBuilder::Proposal.define_method(:create_draft!) do |**|
        raise RuntimeError, "simulated non-Active Record draft persistence failure"
      end

      assert_no_difference("MiaActionDraft.count") do
        assert_difference("ChatMessage.count", 2) do
          post "/api/v1/mia/messages",
            params: { message: "Set Groceries budget to $800 per month" },
            headers: auth_headers(user),
            as: :json
        end
      end
    ensure
      HouseholdFinance::MiaActionDraftBuilder::Proposal.define_method(:create_draft!, original_create_draft)
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_nil body.fetch("mia_action_draft")
    assert_includes body.fetch("assistant_message").fetch("content"), "could not prepare the review card"
    assert_equal [ "Set Groceries budget to $800 per month", body.fetch("assistant_message").fetch("content") ], household.chat_sessions.find_by!(user: user).chat_messages.order(:created_at).pluck(:content)
    assert_equal [ 50_000 ], planned_amounts_for(household.budget_categories.find_by!(name: "Groceries"))
  end

  test "canceling a Mia action draft leaves the annual budget unchanged" do
    user = create_user(email: "mia-action-cancel@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    category = HouseholdFinance::AnnualBudgetManager.new(household).create_category!(name: "Dining Out", stack_key: "discretionary", monthly_amount: 300)

    post "/api/v1/mia/messages",
      params: { message: "Reduce Dining Out budget by $75 per month" },
      headers: auth_headers(user),
      as: :json

    assert_response :created
    draft_id = JSON.parse(response.body).fetch("mia_action_draft").fetch("id")

    assert_difference("HouseholdAuditEvent.count", 1) do
      post "/api/v1/mia_action_drafts/#{draft_id}/cancel",
        headers: auth_headers(user),
        as: :json
    end

    assert_response :success
    assert_equal "canceled", MiaActionDraft.find(draft_id).status
    assert_equal [ 30_000 ], planned_amounts_for(category)
    body = JSON.parse(response.body)
    assert_empty body.fetch("workspace").fetch("budget").fetch("annual_plan").fetch("pending_mia_action_drafts")
    assert_includes body.fetch("workspace").fetch("mia").fetch("messages").last.fetch("content"), "No budget numbers changed"
  end

  test "applying a stale Mia action draft is rejected without partial budget changes" do
    user = create_user(email: "mia-action-stale@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    category = HouseholdFinance::AnnualBudgetManager.new(household).create_category!(name: "Groceries", stack_key: "discretionary", monthly_amount: 500)

    post "/api/v1/mia/messages",
      params: { message: "Set Groceries budget to $800 per month" },
      headers: auth_headers(user),
      as: :json

    assert_response :created
    draft_id = JSON.parse(response.body).fetch("mia_action_draft").fetch("id")
    category.budget_allocations.order(:id).first.update!(planned_amount_cents: 550_00)

    assert_no_difference("HouseholdAuditEvent.count") do
      post "/api/v1/mia_action_drafts/#{draft_id}/apply",
        headers: auth_headers(user),
        as: :json
    end

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body).fetch("errors"), "Budget changed since Mia drafted this. Ask Mia to draft a fresh edit."
    assert_equal "pending", MiaActionDraft.find(draft_id).status
    assert_includes planned_amounts_for(category), 55_000
    refute_includes planned_amounts_for(category), 80_000
  end

  test "mia can draft and apply category rename and reclassification" do
    user = create_user(email: "mia-action-category-edits@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    category = HouseholdFinance::AnnualBudgetManager.new(household).create_category!(name: "Groceries", stack_key: "discretionary", monthly_amount: 500)

    post "/api/v1/mia/messages",
      params: { message: "Rename Groceries category to Food" },
      headers: auth_headers(user),
      as: :json

    assert_response :created
    rename_draft = JSON.parse(response.body).fetch("mia_action_draft")
    assert_equal "update_category", rename_draft.fetch("items").first.fetch("action_type")

    post "/api/v1/mia_action_drafts/#{rename_draft.fetch("id")}/apply",
      headers: auth_headers(user),
      as: :json

    assert_response :success
    assert_equal "Food", category.reload.name
    assert_equal [ 50_000 ], planned_amounts_for(category)

    post "/api/v1/mia/messages",
      params: { message: "Reclassify Food category to non-discretionary" },
      headers: auth_headers(user),
      as: :json

    assert_response :created
    reclassify_draft = JSON.parse(response.body).fetch("mia_action_draft")

    post "/api/v1/mia_action_drafts/#{reclassify_draft.fetch("id")}/apply",
      headers: auth_headers(user),
      as: :json

    assert_response :success
    assert_equal "non_discretionary", category.reload.stack_key
  end

  test "applying a rename draft rejects a target name created after proposal" do
    user = create_user(email: "mia-action-rename-category-stale@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    manager = HouseholdFinance::AnnualBudgetManager.new(household)
    groceries = manager.create_category!(name: "Groceries", stack_key: "discretionary", monthly_amount: 500)

    post "/api/v1/mia/messages",
      params: { message: "Rename Groceries category to Food" },
      headers: auth_headers(user),
      as: :json

    assert_response :created
    draft = JSON.parse(response.body).fetch("mia_action_draft")
    manager.create_category!(name: "food", stack_key: "discretionary", monthly_amount: 125)

    assert_no_difference("BudgetCategory.count") do
      assert_no_difference("HouseholdAuditEvent.count") do
        post "/api/v1/mia_action_drafts/#{draft.fetch('id')}/apply",
          headers: auth_headers(user),
          as: :json
      end
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_includes body.fetch("errors"), "A budget category named Food now exists. Ask Mia to draft a fresh edit for the existing category. Nothing changed."
    assert_equal "pending", MiaActionDraft.find(draft.fetch("id")).status
    assert_equal "Groceries", groceries.reload.name
  end

  test "mia can draft and apply a new budget category" do
    user = create_user(email: "mia-action-create-category@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    HouseholdFinance::AnnualBudgetManager.new(household).ensure_plan!

    post "/api/v1/mia/messages",
      params: { message: "Create a non-discretionary budget category for Daycare at $900 per month" },
      headers: auth_headers(user),
      as: :json

    assert_response :created
    draft = JSON.parse(response.body).fetch("mia_action_draft")
    assert_equal "create_category", draft.fetch("items").first.fetch("action_type")
    refute household.budget_categories.where(name: "Daycare").exists?

    post "/api/v1/mia_action_drafts/#{draft.fetch("id")}/apply",
      headers: auth_headers(user),
      as: :json

    assert_response :success
    category = household.budget_categories.find_by!(name: "Daycare")
    assert_equal "non_discretionary", category.stack_key
    assert_equal [ 90_000 ], planned_amounts_for(category)
  end

  test "mia creates a new category only in the explicitly requested month" do
    user = create_user(email: "mia-action-create-category-single-month@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    HouseholdFinance::AnnualBudgetManager.new(household, year: 2026).ensure_plan!
    intent = HouseholdFinance::MiaIntentResolver::Result.new(
      intent: "budget_action",
      confidence: 0.99,
      continuation: false,
      resolved_message: "Create School Supplies with $75 for August 2026",
      needs_clarification: false,
      clarification: "",
      topic: { type: "budget_action", title: "Create School Supplies", subject: "School Supplies" },
      action: {
        type: "create_category",
        category_id: 0,
        category_name: "",
        target_category_id: 0,
        target_category_name: "",
        new_name: "School Supplies",
        stack_key: "sinking_expected",
        amount: "75",
        months: [ 8 ],
        year: 2026,
        draft_id: 0
      },
      source: "model"
    )
    resolver = Object.new
    resolver.define_singleton_method(:call) { intent }

    with_intent_resolver(resolver) do
      post "/api/v1/mia/messages",
        params: { year: 2026, month: 8, message: "Create School Supplies with $75 for August 2026" },
        headers: auth_headers(user),
        as: :json
    end

    assert_response :created
    body = JSON.parse(response.body)
    item = body.fetch("mia_action_draft").fetch("items").first
    assert_equal [ 8 ], item.fetch("payload").fetch("month_numbers")
    assert_includes item.fetch("description"), "Aug 2026"

    post "/api/v1/mia_action_drafts/#{body.fetch('mia_action_draft').fetch('id')}/apply",
      headers: auth_headers(user),
      as: :json

    assert_response :success
    category = household.budget_categories.find_by!(name: "School Supplies")
    assert_equal 7_500, planned_amount_for_month(category, 8)
    assert_equal 0, planned_amount_for_month(category, 7)
    assert_equal 0, planned_amount_for_month(category, 9)
  end

  test "applying a create-category draft rejects a name that was created after proposal" do
    user = create_user(email: "mia-action-create-category-stale@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    manager = HouseholdFinance::AnnualBudgetManager.new(household)
    manager.ensure_plan!

    post "/api/v1/mia/messages",
      params: { message: "Create a non-discretionary budget category for Daycare at $900 per month" },
      headers: auth_headers(user),
      as: :json

    assert_response :created
    draft = JSON.parse(response.body).fetch("mia_action_draft")
    existing = manager.create_category!(name: "daycare", stack_key: "discretionary", monthly_amount: 125)

    assert_no_difference("BudgetCategory.count") do
      assert_no_difference("HouseholdAuditEvent.count") do
        post "/api/v1/mia_action_drafts/#{draft.fetch('id')}/apply",
          headers: auth_headers(user),
          as: :json
      end
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_includes body.fetch("errors"), "A budget category named Daycare now exists. Ask Mia to draft a fresh edit for the existing category. Nothing changed."
    assert_equal "pending", MiaActionDraft.find(draft.fetch("id")).status
    assert_equal existing.id, household.budget_categories.where("LOWER(name) = ?", "daycare").sole.id
    assert_equal [ 12_500 ], planned_amounts_for(existing)
  end

  test "create-category unique-index races return a stale review error instead of a server error" do
    user = create_user(email: "mia-action-create-category-race@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    HouseholdFinance::AnnualBudgetManager.new(household).ensure_plan!

    post "/api/v1/mia/messages",
      params: { message: "Create a non-discretionary budget category for Daycare at $900 per month" },
      headers: auth_headers(user),
      as: :json

    assert_response :created
    draft = JSON.parse(response.body).fetch("mia_action_draft")
    original_create_category = HouseholdFinance::AnnualBudgetManager.instance_method(:create_category!)
    begin
      HouseholdFinance::AnnualBudgetManager.define_method(:create_category!) do |**|
        raise ActiveRecord::RecordNotUnique, "simulated concurrent category insert"
      end

      post "/api/v1/mia_action_drafts/#{draft.fetch('id')}/apply",
        headers: auth_headers(user),
        as: :json
    ensure
      HouseholdFinance::AnnualBudgetManager.define_method(:create_category!, original_create_category)
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_includes body.fetch("errors"), "A budget category named Daycare now exists. Ask Mia to draft a fresh edit for the existing category. Nothing changed."
    assert_equal "pending", MiaActionDraft.find(draft.fetch("id")).status
    refute household.budget_categories.where("LOWER(name) = ?", "daycare").exists?
  end

  test "model resolved reported spend creates the pending review immediately with a Rails category suggestion" do
    user = create_user(email: "mia-model-transaction-create@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    manager = HouseholdFinance::AnnualBudgetManager.new(household, year: Date.current.year)
    dining = manager.create_category!(name: "Dining Out", stack_key: "discretionary", monthly_amount: 300)
    intent = HouseholdFinance::MiaIntentResolver::Result.new(
      intent: "transaction_report",
      confidence: 0.99,
      continuation: false,
      resolved_message: "Create a pending review for $12.35 at Walkthrough Cafe Retest today",
      needs_clarification: false,
      clarification: "",
      topic: { type: "transaction_report", title: "Walkthrough Cafe Retest expense", subject: "Walkthrough Cafe Retest" },
      action: {
        type: "create_transaction_draft",
        draft_id: 0,
        merchant: "Walkthrough Cafe Retest",
        amount: "12.35",
        occurred_on: Date.current.iso8601,
        category_id: 0,
        category_name: "",
        stack_key: "",
        splits: []
      },
      source: "model"
    )
    resolver = Object.new
    resolver.define_singleton_method(:call) { intent }

    assert_difference("TransactionDraft.count", 1) do
      assert_no_difference("HouseholdTransaction.count") do
        with_intent_resolver(resolver) do
          post "/api/v1/mia/messages",
            params: { message: "I spent $12.35 at Walkthrough Cafe Retest today." },
            headers: auth_headers(user),
            as: :json
        end
      end
    end

    assert_response :created
    body = JSON.parse(response.body)
    draft = household.transaction_drafts.find(body.dig("transaction_draft", "id"))
    assert_equal "pending", draft.status
    assert_equal dining.id, draft.budget_category_id
    assert_equal 12_35, draft.total_amount_cents
    assert_equal Date.current, draft.occurred_on
    assert_includes body.dig("assistant_message", "content"), "drafted this for review"
    assert_equal draft.id, body.dig("budget", "annual_plan", "pending_transaction_drafts", 0, "id")
  end

  test "model resolved transaction correction updates the pending review without changing actuals" do
    user = create_user(email: "mia-transaction-correction@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    manager = HouseholdFinance::AnnualBudgetManager.new(household, year: Date.current.year)
    dining = manager.create_category!(name: "Dining Out", stack_key: "discretionary", monthly_amount: 300)
    draft = household.transaction_drafts.create!(
      occurred_on: Date.current,
      merchant: "Walkthrough Cafe",
      total_amount_cents: 12_34,
      budget_category: dining,
      source_type: "manual_chat",
      status: "pending",
      raw_input: "I spent $12.34 at Walkthrough Cafe today"
    )
    draft.transaction_draft_splits.create!(budget_category: dining, category_name: dining.name, stack_key: dining.stack_key, amount_cents: 12_34)
    intent = HouseholdFinance::MiaIntentResolver::Result.new(
      intent: "transaction_draft_action",
      confidence: 0.99,
      continuation: true,
      resolved_message: "Change the pending Walkthrough Cafe date to #{Date.current.prev_day.iso8601}",
      needs_clarification: false,
      clarification: "",
      topic: { type: "transaction_draft", title: "Walkthrough Cafe review", subject: "Walkthrough Cafe" },
      action: { type: "update_transaction_draft", draft_id: draft.id, occurred_on: Date.current.prev_day.iso8601 },
      source: "model"
    )
    resolver = Object.new
    resolver.define_singleton_method(:call) { intent }

    assert_no_difference("HouseholdTransaction.count") do
      with_intent_resolver(resolver) do
        post "/api/v1/mia/messages",
          params: { year: Date.current.year, month: Date.current.month, message: "Actually it wasn't today, it was yesterday" },
          headers: auth_headers(user),
          as: :json
      end
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal Date.current.prev_day.iso8601, body.dig("transaction_draft", "occurred_on")
    assert_equal Date.current.prev_day, draft.reload.occurred_on
    assert_equal "pending", draft.status
    assert_includes body.dig("assistant_message", "content"), "updated"
    assert_includes body.dig("assistant_message", "content"), "actuals did not change"
    refute_includes body.dig("assistant_message", "content"), "I will update"
    pending = body.dig("budget", "annual_plan", "pending_transaction_drafts")
    assert_equal Date.current.prev_day.iso8601, pending.find { |item| item.fetch("id") == draft.id }.fetch("occurred_on")
  end

  test "explicit yesterday correction safely updates one pending transaction when intent provider is unavailable" do
    user = create_user(email: "mia-transaction-correction-fallback@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    manager = HouseholdFinance::AnnualBudgetManager.new(household, year: Date.current.year)
    dining = manager.create_category!(name: "Dining Out", stack_key: "discretionary", monthly_amount: 300)
    draft = household.transaction_drafts.create!(
      occurred_on: Date.current,
      merchant: "Fallback Cafe",
      total_amount_cents: 9_50,
      budget_category: dining,
      source_type: "manual_chat",
      status: "pending",
      raw_input: "I spent $9.50 today"
    )
    draft.transaction_draft_splits.create!(budget_category: dining, category_name: dining.name, stack_key: dining.stack_key, amount_cents: 9_50)
    unavailable_resolver = Object.new
    unavailable_resolver.define_singleton_method(:call) { nil }

    assert_no_difference("HouseholdTransaction.count") do
      with_intent_resolver(unavailable_resolver) do
        post "/api/v1/mia/messages",
          params: { message: "Actually it wasn't today, it was yesterday" },
          headers: auth_headers(user),
          as: :json
      end
    end

    assert_response :created
    assert_equal Date.current.prev_day, draft.reload.occurred_on
    assert_equal "pending", draft.status
    content = JSON.parse(response.body).dig("assistant_message", "content")
    assert_includes content, "updated the pending Fallback Cafe review"
    assert_includes content, "actuals did not change"
  end

  test "model resolved explicit ignore-all request clears pending reviews without changing actuals" do
    user = create_user(email: "mia-ignore-all-reviews@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    manager = HouseholdFinance::AnnualBudgetManager.new(household, year: Date.current.year)
    category = manager.create_category!(name: "Flexible spending", stack_key: "discretionary", monthly_amount: 300)
    2.times do |index|
      draft = household.transaction_drafts.create!(
        occurred_on: Date.current,
        merchant: "Ignore All #{index}",
        total_amount_cents: (index + 1) * 1_000,
        budget_category: category,
        source_type: "manual_chat",
        status: "pending",
        raw_input: "Ignore all test"
      )
      draft.transaction_draft_splits.create!(budget_category: category, category_name: category.name, stack_key: category.stack_key, amount_cents: draft.total_amount_cents)
    end
    intent = HouseholdFinance::MiaIntentResolver::Result.new(
      intent: "transaction_draft_action",
      confidence: 0.99,
      continuation: false,
      resolved_message: "Ignore all pending transaction reviews",
      needs_clarification: false,
      clarification: "",
      topic: { type: "transaction_review", title: "Clear reviews", subject: "all pending reviews" },
      action: { type: "ignore_transaction_drafts", all_pending: true },
      source: "model"
    )
    resolver = Object.new
    resolver.define_singleton_method(:call) { intent }

    assert_no_difference("HouseholdTransaction.count") do
      with_intent_resolver(resolver) do
        post "/api/v1/mia/messages",
          params: { message: "Clear all of them and ignore every pending review" },
          headers: auth_headers(user),
          as: :json
      end
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_includes body.dig("assistant_message", "content"), "Ignored 2 pending transaction reviews"
    assert_includes body.dig("assistant_message", "content"), "Actuals did not change"
    assert_empty household.transaction_drafts.pending
    assert_empty body.dig("budget", "annual_plan", "pending_transaction_drafts")
  end

  test "mia can draft and apply a planned-dollar move between categories" do
    user = create_user(email: "mia-action-move@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    manager = HouseholdFinance::AnnualBudgetManager.new(household)
    dining = manager.create_category!(name: "Dining Out", stack_key: "discretionary", monthly_amount: 300)
    groceries = manager.create_category!(name: "Groceries", stack_key: "discretionary", monthly_amount: 500)

    post "/api/v1/mia/messages",
      params: { message: "Move $100 from Dining Out to Groceries" },
      headers: auth_headers(user),
      as: :json

    assert_response :created
    draft = JSON.parse(response.body).fetch("mia_action_draft")
    assert_equal 2, draft.fetch("items").length

    post "/api/v1/mia_action_drafts/#{draft.fetch("id")}/apply",
      headers: auth_headers(user),
      as: :json

    assert_response :success
    assert_equal [ 20_000 ], planned_amounts_for(dining)
    assert_equal [ 60_000 ], planned_amounts_for(groceries)
  end

  private

  def with_intent_resolver(resolver)
    singleton = class << HouseholdFinance::MiaIntentResolver; self; end
    original_new = singleton.instance_method(:new)
    singleton.define_method(:new) { |**_kwargs| resolver }
    yield
  ensure
    singleton.send(:remove_method, :new) if singleton.method_defined?(:new)
    singleton.define_method(:new, original_new)
  end

  def with_mia_responder(responder)
    singleton = class << Demo::MiaResponder; self; end
    original_new = singleton.instance_method(:new)
    singleton.define_method(:new) { |**_kwargs| responder }
    yield
  ensure
    singleton.send(:remove_method, :new) if singleton.method_defined?(:new)
    singleton.define_method(:new, original_new)
  end

  def create_user(email:)
    User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: email,
      role: "participant",
      invitation_status: "accepted"
    )
  end

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end

  def planned_amounts_for(category)
    BudgetAllocation.uncached do
      BudgetAllocation.where(budget_category_id: category.id).order(:id).pluck(:planned_amount_cents).uniq
    end
  end

  def allocation_sources_for(category)
    BudgetAllocation.uncached do
      BudgetAllocation.where(budget_category_id: category.id).order(:id).pluck(:source).uniq
    end
  end

  def planned_amount_for_month(category, month)
    BudgetAllocation.uncached do
      BudgetAllocation
        .joins(:budget_period)
        .where(budget_category_id: category.id)
        .find_by!(budget_periods: { starts_on: Date.new(Date.current.year, month, 1) })
        .planned_amount_cents
    end
  end
end
