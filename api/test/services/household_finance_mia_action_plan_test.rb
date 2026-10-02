require "test_helper"

class HouseholdFinanceMiaActionPlanTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      clerk_id: "mia_plan_#{SecureRandom.hex(4)}",
      email: "mia-plan-#{SecureRandom.hex(4)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: Date.current.year)
    @account = @household.accounts.create!(label: "Everyday checking", account_type: "checking", balance_cents: 100_00, balance_known: true)
    @goal = @household.goals.create!(
      label: "Family trip", goal_type: "travel", record_kind: "tracked",
      target_amount_cents: 5_000_00, target_amount_known: true,
      current_amount_cents: 500_00, current_amount_known: true
    )
  end

  test "builds one ordered database plan from exact participant spans" do
    result = build_plan

    assert_equal "action_plan", result.proposal.draft_type
    assert_equal 2, result.proposal.items.length
    assert_equal [ "Set checking to $250", "and set trip progress to $900" ], result.proposal.items.map(&:source_text)
    assert_equal [ 0, 21 ], result.proposal.items.map(&:source_start)
    draft = persist(result.proposal)
    presented = HouseholdFinance::MiaActionDraftPresenter.new(draft).call
    assert_equal [ 0, 1 ], presented.fetch(:items).map { |item| item.fetch(:position) }
    assert_equal [ "My Profile", "My Profile" ], presented.fetch(:items).map { |item| item.fetch(:manual_section) }
    assert_equal 2, presented.fetch(:remaining_item_count)
  end

  test "apply all is atomic when a later item is stale" do
    draft = persist(build_plan.proposal)
    @goal.update!(current_amount_cents: 600_00)

    result = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call(idempotency_key: "atomic-stale")

    assert_not result.success?
    assert_includes result.errors.to_sentence, "changed since"
    assert_equal 100_00, @account.reload.balance_cents
    assert_equal 600_00, @goal.reload.current_amount_cents
    assert_equal "pending", draft.reload.status
    assert_empty draft.mia_action_items.where.not(applied_at: nil)
    assert_empty @household.mia_action_draft_applications.where(idempotency_key: "atomic-stale")
  end

  test "partial selection records progress and idempotently finishes the remaining plan" do
    draft = persist(build_plan.proposal)
    account_item, goal_item = draft.mia_action_items.to_a

    first = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call(
      idempotency_key: "partial-one",
      selected_item_ids: [ account_item.id ]
    )
    assert first.success?, first.errors.to_sentence
    assert_equal "partially_applied", draft.reload.status
    assert_equal 250_00, @account.reload.balance_cents
    assert_equal 500_00, @goal.reload.current_amount_cents
    assert account_item.reload.applied_at
    assert_nil goal_item.reload.applied_at

    replay = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call(
      idempotency_key: "partial-one",
      selected_item_ids: [ account_item.id ]
    )
    assert replay.success?
    assert replay.replayed?

    final = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call(
      idempotency_key: "partial-two",
      selected_item_ids: [ goal_item.id ]
    )
    assert final.success?, final.errors.to_sentence
    assert_equal "applied", draft.reload.status
    assert_equal 900_00, @goal.reload.current_amount_cents
  end

  test "canceling a partial plan preserves applied steps and idempotently cancels only the remainder" do
    draft = persist(build_plan.proposal)
    account_item, goal_item = draft.mia_action_items.to_a
    applied = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call(
      idempotency_key: "cancel-partial-apply", selected_item_ids: [ account_item.id ]
    )
    assert applied.success?, applied.errors.to_sentence

    canceled = HouseholdFinance::MiaActionDraftCanceler.new(draft, user: @user).call(idempotency_key: "cancel-partial")
    assert canceled.success?, canceled.errors.to_sentence
    assert_equal "cancel", canceled.application.request_kind
    assert_equal [ goal_item.id ], canceled.application.selected_item_ids
    assert account_item.reload.applied_at
    assert_nil account_item.canceled_at
    assert goal_item.reload.canceled_at
    assert_equal @user, goal_item.canceled_by_user
    assert_equal "canceled", draft.reload.status
    assert_equal 250_00, @account.reload.balance_cents
    assert_equal 500_00, @goal.reload.current_amount_cents

    replay = HouseholdFinance::MiaActionDraftCanceler.new(draft, user: @user).call(idempotency_key: "cancel-partial")
    assert replay.success?
    assert replay.replayed?
    assert_equal canceled.application.id, replay.application.id

    conflict = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call(
      idempotency_key: "cancel-partial", selected_item_ids: [ goal_item.id ]
    )
    assert_not conflict.success?
    assert conflict.conflict?
  end

  test "partial selection enforces explicit dependency closure" do
    draft = persist(build_plan(dependencies: [ [], [ 0 ] ]).proposal)
    account_item, goal_item = draft.mia_action_items.to_a

    rejected = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call(
      idempotency_key: "missing-dependency",
      selected_item_ids: [ goal_item.id ]
    )
    assert_not rejected.success?
    assert_includes rejected.errors.to_sentence, "earlier required"
    assert_equal 100_00, @account.reload.balance_cents
    assert_equal 500_00, @goal.reload.current_amount_cents

    applied = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call(
      idempotency_key: "with-dependency",
      selected_item_ids: [ account_item.id, goal_item.id ]
    )
    assert applied.success?, applied.errors.to_sentence
  end

  test "legacy single-domain reviews cannot be partially applied" do
    proposal = HouseholdFinance::MiaActionDraftBuilder.new(
      @household,
      user: @user,
      annual_budget_manager: @manager,
      selected_month: Date.current.month,
      raw_input: "Set income to $5,000 and flexible spending to $800",
      command: { type: "update_household_setup", setup_updates: { primary_income: "5000", flexible_spend: "800" } }
    ).call.proposal
    draft = persist(proposal)

    result = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call(
      idempotency_key: "legacy-partial",
      selected_item_ids: [ draft.mia_action_items.first.id ]
    )

    assert_not result.success?
    assert_includes result.errors.to_sentence, "Only household action plans"
    assert_equal "pending", draft.reload.status
    assert_equal 0, HouseholdFinance::DataPresenter.new(@household.reload, user: @user).setup_values.fetch(:primary_income)
  end

  test "a compound plan with setup confirmations applies only as a full remaining plan" do
    prompt = "Set income to $5,000 and set checking to $250"
    result = HouseholdFinance::MiaActionPlanBuilder.new(
      @household,
      user: @user,
      annual_budget_manager: @manager,
      selected_month: Date.current.month,
      raw_input: prompt,
      actions: [
        {
          source_text: "Set income to $5,000",
          depends_on: [],
          action: { type: "update_household_setup", setup_updates: { primary_income: "5000" } }
        },
        {
          source_text: "and set checking to $250",
          depends_on: [],
          action: { type: "update_account", account_id: @account.id, account_name: @account.label, amount: "250" }
        }
      ]
    ).call
    draft = persist(result.proposal)
    account_item = draft.mia_action_items.find_by!(action_type: "update_account")

    partial = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call(
      idempotency_key: "setup-plan-partial",
      selected_item_ids: [ account_item.id ]
    )
    assert_not partial.success?
    assert_includes partial.errors.to_sentence, "Starting-picture confirmations"
    assert_equal 100_00, @account.reload.balance_cents

    complete = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call(
      idempotency_key: "setup-plan-all",
      selected_item_ids: draft.mia_action_items.pluck(:id)
    )
    assert complete.success?, complete.errors.to_sentence
    assert_equal "applied", draft.reload.status
    assert_equal 250_00, @account.reload.balance_cents
    assert_equal 5_000, HouseholdFinance::DataPresenter.new(@household.reload, user: @user).setup_values.fetch(:primary_income)
  end

  test "same idempotency key cannot be reused for another selection" do
    draft = persist(build_plan.proposal)
    account_item, goal_item = draft.mia_action_items.to_a
    assert HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call(
      idempotency_key: "selection-key", selected_item_ids: [ account_item.id ]
    ).success?

    conflict = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call(
      idempotency_key: "selection-key", selected_item_ids: [ goal_item.id ]
    )
    assert_not conflict.success?
    assert_includes conflict.errors.to_sentence, "different Mia plan selection"
  end

  test "prepared operation tampering rejects the whole plan" do
    draft = persist(build_plan.proposal)
    item = draft.mia_action_items.second
    item.update_columns(prepared_operation_fingerprint: "0" * 64)

    result = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call(idempotency_key: "tampered")

    assert_not result.success?
    assert_includes result.errors, HouseholdFinance::MiaActionDraftApplier::INCOMPLETE_DRAFT_MESSAGE
    assert_equal 100_00, @account.reload.balance_cents
    assert_equal 500_00, @goal.reload.current_amount_cents
  end

  test "another household member cannot apply a plan they cannot access" do
    outsider = User.create!(clerk_id: "outsider_#{SecureRandom.hex(4)}", email: "outsider-#{SecureRandom.hex(4)}@example.com", role: "participant", invitation_status: "accepted")
    draft = persist(build_plan.proposal)

    result = HouseholdFinance::MiaActionDraftApplier.new(draft, user: outsider).call(idempotency_key: "outsider")

    assert_not result.success?
    assert_includes result.errors.to_sentence, "permission"
    assert_equal 100_00, @account.reload.balance_cents
  end

  test "duplicate or nonparticipant source spans cannot produce a partial plan" do
    duplicate = build_plan(source_two: "Set checking to $250")
    assert_nil duplicate.proposal
    assert_includes duplicate.response, "exact message text"

    missing = build_plan(source_two: "invented instruction")
    assert_nil missing.proposal
    assert_includes missing.response, "exact message text"
  end

  test "rejects a current nonbudget change mixed with a future budget change without persisting a draft" do
    category = @manager.create_category!(name: "Groceries", stack_key: "discretionary", monthly_amount: 500)
    prompt = "Set checking to $250 and set #{category.name} to $700 next year"

    assert_no_difference("MiaActionDraft.count") do
      result = HouseholdFinance::MiaActionPlanBuilder.new(
        @household,
        user: @user,
        annual_budget_manager: @manager,
        selected_month: Date.current.month,
        raw_input: prompt,
        actions: [
          {
            source_text: "Set checking to $250", depends_on: [],
            action: { type: "update_account", account_id: @account.id, account_name: @account.label, amount: "250" }
          },
          {
            source_text: "set #{category.name} to $700 next year", depends_on: [],
            action: {
              type: "set_allocation", category_id: category.id, category_name: category.name,
              amount: "700", months: [ Date.current.month ], year: Date.current.year + 1
            }
          }
        ]
      ).call

      assert_nil result.proposal
      assert_includes result.response, "only the budget year you are viewing"
      assert_includes result.response, "Nothing changed"
    end
  end

  test "rejects one compound plan that targets multiple budget years" do
    category = @manager.create_category!(name: "Groceries", stack_key: "discretionary", monthly_amount: 500)
    prompt = "Set #{category.name} to $700 next year and to $800 the year after"

    result = HouseholdFinance::MiaActionPlanBuilder.new(
      @household,
      user: @user,
      annual_budget_manager: @manager,
      selected_month: Date.current.month,
      raw_input: prompt,
      actions: [
        {
          source_text: "Set #{category.name} to $700 next year", depends_on: [],
          action: {
            type: "set_allocation", category_id: category.id, category_name: category.name,
            amount: "700", months: [ Date.current.month ], year: Date.current.year + 1
          }
        },
        {
          source_text: "to $800 the year after", depends_on: [],
          action: {
            type: "set_allocation", category_id: category.id, category_name: category.name,
            amount: "800", months: [ Date.current.month ], year: Date.current.year + 2
          }
        }
      ]
    ).call

    assert_nil result.proposal
    assert_includes result.response, (Date.current.year + 1).to_s
    assert_includes result.response, (Date.current.year + 2).to_s
    assert_includes result.response, "Nothing changed"
  end

  test "database plan reference survives old transcript newer reviews and a changed budget year" do
    draft = persist(build_plan(dependencies: [ [], [ 0 ] ]).proposal)
    open_draft = persist(build_plan.proposal)
    first_item, second_item = draft.mia_action_items.to_a
    first_item.update!(applied_at: Time.current)
    draft.update!(status: "partially_applied")
    session = @household.chat_sessions.find_by!(user: @user)
    34.times do |index|
      session.chat_messages.create!(role: index.even? ? "user" : "assistant", content: "Unrelated context #{index}")
    end
    session.update!(
      active_topic: {
        schema_version: 5, id: SecureRandom.uuid, type: "action_plan", title: draft.title,
        subject: "Household action plan", status: "pending_review", mia_action_draft_id: draft.id
      },
      open_topics: [ {
        schema_version: 5, id: SecureRandom.uuid, type: "action_plan", title: draft.title,
        subject: "Household action plan", status: "pending_review", mia_action_draft_id: draft.id
      }, {
        schema_version: 5, id: SecureRandom.uuid, type: "action_plan", title: open_draft.title,
        subject: "Another household action plan", status: "pending_review", mia_action_draft_id: open_draft.id
      } ]
    )

    recall_user = session.chat_messages.create!(role: "user", content: "What were we discussing?")
    recall_assistant = session.chat_messages.create!(role: "assistant", content: "The household action plan is still waiting for review.")
    recall_intent = HouseholdFinance::MiaIntentResolver::Result.new(
      intent: "recall", confidence: 0.99, continuation: false,
      resolved_message: "Recall the household action plan", needs_clarification: false, clarification: "",
      topic: { type: "action_plan", title: draft.title, subject: "Household action plan" },
      action: { type: "none" }, source: "model"
    )
    assert HouseholdFinance::MiaConversationStateUpdater.new(
      session,
      intent_result: recall_intent,
      user_message: recall_user,
      assistant_message: recall_assistant
    ).call

    context = HouseholdFinance::ConversationContextBuilder.new(session, household: @household).call

    assert_equal 5, context.dig(:active_topic, :schema_version)
    assert_equal draft.id, context.dig(:active_topic, :action_plan, :draft_id)
    assert_equal [ second_item.id ], context.dig(:active_topic, :action_plan, :remaining_item_ids)
    assert_equal open_draft.id, context.fetch(:open_topics).find { |topic| topic.dig(:action_plan, :draft_id) == open_draft.id }.dig(:action_plan, :draft_id)

    viewed_year = Date.current.year + 1
    12.times do |index|
      @household.mia_action_drafts.create!(
        requested_by_user: @user, status: "pending", draft_type: "goal_plan", year: viewed_year,
        title: "Newer review #{index}", summary: "A newer pending review", source_prompt: "Newer request #{index}"
      )
    end
    viewed_manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: viewed_year)
    viewed_manager.ensure_plan!
    viewed_plan = viewed_manager.plan_data
    refute_includes viewed_plan.fetch(:pending_mia_action_drafts).map { |review| review.fetch(:id) }, draft.id

    durable_context = HouseholdFinance::MiaIntentContextBuilder.new(
      @household,
      annual_plan: viewed_plan,
      conversation_context: context,
      transcript: session.chat_messages.order(id: :desc).limit(32).reverse.map { |message| { role: message.role, content: message.content } },
      selected_month: Date.current.month
    ).call
    pending_plan = durable_context.fetch(:pending_budget_reviews).find { |review| review.fetch(:id) == draft.id }
    open_pending_plan = durable_context.fetch(:pending_budget_reviews).find { |review| review.fetch(:id) == open_draft.id }
    assert pending_plan
    assert open_pending_plan
    assert_equal open_draft.mia_action_items.pluck(:id), open_pending_plan.fetch(:items).map { |item| item.fetch(:id) }
    assert_equal [ first_item.id, second_item.id ], pending_plan.fetch(:items).map { |item| item.fetch(:id) }
    assert_equal %w[account goal], pending_plan.fetch(:items).map { |item| item.fetch(:domain) }
    assert_equal %w[applied pending], pending_plan.fetch(:items).map { |item| item.fetch(:status) }
    assert_equal [ [], [ first_item.id ] ], pending_plan.fetch(:items).map { |item| item.fetch(:dependency_item_ids) }
    assert_equal "partially_applied", pending_plan.fetch(:status)
    assert_equal 1, pending_plan.fetch(:remaining_item_count)
    refute durable_context.to_json.include?(draft.source_prompt)
    refute durable_context.to_json.include?("prepared_operation")

    selection_resolver = HouseholdFinance::MiaIntentResolver.new(
      user_message: "Bring back only the goal part",
      context: durable_context,
      api_key: "test-key",
      transport: ->(_payload) { raise "the test builds the parsed provider result directly" }
    )
    selected_action = selection_resolver.send(:default_action_payload).merge(
      type: "review_pending_action", draft_id: draft.id, selected_item_ids: [ second_item.id ]
    )
    resolution = selection_resolver.send(:build_result, {
      intent: "budget_action", confidence: 0.99, continuation: true,
      resolved_message: "Review only the goal step", needs_clarification: false, clarification: "",
      topic: { type: "action_plan", title: draft.title, subject: "Household action plan" },
      action: selected_action, write_plan: { title: "", actions: [] }, read_only_plan: { title: "", items: [] }
    })
    assert resolution.actionable?
    assert_equal [ second_item.id ], resolution.action.fetch(:selected_item_ids)

    selected = HouseholdFinance::MiaActionDraftBuilder.new(
      @household,
      user: @user,
      annual_budget_manager: @manager,
      selected_month: Date.current.month,
      raw_input: "Bring back only the goal part",
      command: resolution.action
    ).call
    assert_equal draft, selected.existing_draft
    assert_equal [ second_item.id ], selected.selected_item_ids
    assert_includes selected.response, "selected the requested steps"
  end

  private

  def build_plan(dependencies: [ [], [] ], source_two: "and set trip progress to $900")
    prompt = "Set checking to $250 and set trip progress to $900"
    HouseholdFinance::MiaActionPlanBuilder.new(
      @household,
      user: @user,
      annual_budget_manager: @manager,
      selected_month: Date.current.month,
      raw_input: prompt,
      actions: [
        {
          source_text: "Set checking to $250",
          depends_on: dependencies.fetch(0),
          action: { type: "update_account", account_id: @account.id, account_name: @account.label, amount: "250" }
        },
        {
          source_text: source_two,
          depends_on: dependencies.fetch(1),
          action: { type: "update_goal", goal_id: @goal.id, goal_name: @goal.label, current_amount: "900" }
        }
      ]
    ).call
  end

  def persist(proposal)
    session = @household.chat_sessions.find_or_create_by!(user: @user) { |record| record.title = "Ask Mia" }
    proposal.create_draft!(
      source_chat_message: session.chat_messages.create!(role: "user", content: proposal.source_prompt),
      assistant_chat_message: session.chat_messages.create!(role: "assistant", content: "Review this plan")
    )
  end
end
