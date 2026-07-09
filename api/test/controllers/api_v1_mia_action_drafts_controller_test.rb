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
    assert_includes apply_body.fetch("workspace").fetch("mia").fetch("messages").last.fetch("content"), "Applied Mia’s budget draft"
  end

  test "mia chat persists messages even when action draft persistence fails" do
    user = create_user(email: "mia-action-persistence-failure@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    HouseholdFinance::AnnualBudgetManager.new(household).create_category!(name: "Groceries", stack_key: "discretionary", monthly_amount: 500)

    original_create_draft = HouseholdFinance::MiaActionDraftBuilder::Proposal.instance_method(:create_draft!)
    begin
      HouseholdFinance::MiaActionDraftBuilder::Proposal.define_method(:create_draft!) do |**|
        raise ActiveRecord::StatementInvalid, "simulated draft persistence failure"
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
end
