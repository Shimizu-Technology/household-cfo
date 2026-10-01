require "test_helper"

class ApiV1HouseholdMemoriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @owner = create_user("memory-owner@example.com")
    @household = HouseholdFinance::WorkspaceResolver.new(@owner).household
  end

  test "participant explicitly creates edits confirms rejects and forgets bounded memories" do
    assert_difference("@household.household_memories.count", 1) do
      post "/api/v1/household_memories", params: {
        memory: {
          category: "coaching_style", display_value: "Ask one question at a time.",
          sensitivity: "ordinary", visibility: "private", confirmed: true, request_key: "memory-request-1"
        }
      }, headers: auth_headers(@owner), as: :json
    end
    assert_response :created
    memory = @household.household_memories.last
    assert_equal "user_confirmed", memory.status
    assert_equal "Ask one question at a time.", memory.display_value

    assert_no_difference("@household.household_memories.count") do
      post "/api/v1/household_memories", params: {
        memory: {
          category: "coaching_style", display_value: "Ask one question at a time.",
          sensitivity: "ordinary", visibility: "private", confirmed: true, request_key: "memory-request-1"
        }
      }, headers: auth_headers(@owner), as: :json
    end
    assert_response :success
    assert_equal memory.id, JSON.parse(response.body).dig("memory", "id")

    post "/api/v1/household_memories", params: {
      memory: { category: "goal", display_value: "Different payload", request_key: "memory-request-1" }
    }, headers: auth_headers(@owner), as: :json
    assert_response :conflict

    patch "/api/v1/household_memories/#{memory.id}", params: {
      memory: { display_value: "Give me one clear next step.", visibility: "household" }
    }, headers: auth_headers(@owner), as: :json
    assert_response :success
    assert_equal "Give me one clear next step.", memory.reload.display_value

    post "/api/v1/household_memories/#{memory.id}/reject", headers: auth_headers(@owner)
    assert_response :success
    assert_equal "rejected", memory.reload.status

    post "/api/v1/household_memories/#{memory.id}/confirm", headers: auth_headers(@owner)
    assert_response :success
    assert_equal "user_confirmed", memory.reload.status

    assert_difference("@household.household_memories.count", -1) do
      delete "/api/v1/household_memories/#{memory.id}", headers: auth_headers(@owner)
    end
    assert_response :no_content
  end

  test "sensitive memory always requires an explicit second confirmation" do
    post "/api/v1/household_memories", params: {
      memory: {
        category: "constraint", display_value: "I am dealing with a private health issue.",
        sensitivity: "sensitive", visibility: "private", confirmed: true
      }
    }, headers: auth_headers(@owner), as: :json

    assert_response :created
    memory = @household.household_memories.last
    assert_equal "pending_confirmation", memory.status
    assert_not memory.active?
    assert_empty HouseholdFinance::MiaMemoryContextBuilder.new(@household, user: @owner).call.fetch(:memories)

    post "/api/v1/household_memories/#{memory.id}/confirm", headers: auth_headers(@owner)
    assert_equal [ memory.id ], HouseholdFinance::MiaMemoryContextBuilder.new(@household, user: @owner).call.fetch(:memories).pluck(:id)

    patch "/api/v1/household_memories/#{memory.id}", params: {
      memory: { display_value: "A different private medical issue." }
    }, headers: auth_headers(@owner), as: :json
    assert_response :success
    assert_equal "pending_confirmation", memory.reload.status
    assert_not memory.active?
  end

  test "private memories stay owner-only while household memories are shared with a partner" do
    partner = create_user("memory-partner@example.com")
    @household.household_memberships.create!(user: partner, role: "partner")
    private_memory = create_memory(display_value: "Use shorter replies", visibility: "private")
    shared_memory = create_memory(display_value: "Check in on our relocation goal", visibility: "household")

    get "/api/v1/household_memories", headers: auth_headers(partner)
    assert_response :success
    ids = JSON.parse(response.body).fetch("memories").pluck("id")
    assert_not_includes ids, private_memory.id
    assert_includes ids, shared_memory.id

    patch "/api/v1/household_memories/#{shared_memory.id}", params: { memory: { display_value: "Take it over" } }, headers: auth_headers(partner), as: :json
    assert_response :forbidden
    assert_equal "Check in on our relocation goal", shared_memory.reload.display_value
  end

  test "cross-household access and coach visibility are denied" do
    memory = create_memory(display_value: "Private constraint", visibility: "household")
    stranger = create_user("memory-stranger@example.com")
    HouseholdFinance::WorkspaceResolver.new(stranger).household

    delete "/api/v1/household_memories/#{memory.id}", headers: auth_headers(stranger)
    assert_response :not_found
    assert HouseholdMemory.exists?(memory.id)

    coach = create_user("memory-coach@example.com", role: "coach")
    @household.household_memberships.create!(user: coach, role: "coach_viewer")
    get "/api/v1/household_memories", headers: auth_headers(coach)
    assert_response :forbidden
    assert_not_includes response.body, "Private constraint"
  end

  test "pausing personalization removes memories from context without changing financial facts or deleting memory" do
    memory = create_memory(display_value: "Use calm language", visibility: "private")
    account = @household.accounts.create!(label: "Emergency savings", account_type: "checking", balance_cents: 100_000)
    before = account.attributes

    patch "/api/v1/mia_memory_settings", params: { personalization: { paused: true } }, headers: auth_headers(@owner), as: :json
    assert_response :success
    context = HouseholdFinance::MiaMemoryContextBuilder.new(@household, user: @owner).call
    assert context.fetch(:paused)
    assert_empty context.fetch(:memories)
    assert HouseholdMemory.exists?(memory.id)
    assert_equal before, account.reload.attributes

    patch "/api/v1/mia_memory_settings", params: { personalization: { paused: false } }, headers: auth_headers(@owner), as: :json
    assert_equal [ memory.id ], HouseholdFinance::MiaMemoryContextBuilder.new(@household, user: @owner).call.fetch(:memories).pluck(:id)
  end

  test "clearing Mia chat does not delete curated memory" do
    memory = create_memory(display_value: "Follow up weekly", visibility: "private")
    session = @household.chat_sessions.create!(user: @owner, title: "Ask Mia")
    session.chat_messages.create!(role: "user", content: "A transcript that should be cleared")

    delete "/api/v1/mia/messages", headers: auth_headers(@owner)

    assert_response :no_content
    assert_empty session.chat_messages.reload
    assert HouseholdMemory.exists?(memory.id)
    assert_equal "Follow up weekly", memory.reload.display_value
  end

  test "validations bound memory text and structured data" do
    post "/api/v1/household_memories", params: {
      memory: { category: "financial_truth", display_value: "x" * 501, structured_value: { payload: "y" * 2_001 } }
    }, headers: auth_headers(@owner), as: :json
    assert_response :unprocessable_entity
    assert_empty @household.household_memories
  end

  test "explicit remember command saves only the requested text and what do you remember is deterministic" do
    post "/api/v1/mia/messages", params: {
      message: "Remember that I prefer replies with one clear next step.", request_id: "remember-command-1"
    }, headers: auth_headers(@owner), as: :json

    assert_response :created
    memory = @household.household_memories.find_by!(request_key: "mia:remember-command-1")
    assert_equal "I prefer replies with one clear next step.", memory.display_value
    assert_equal "mia_command", memory.source_kind
    assert_equal "coaching_style", memory.category
    assert_equal "user_confirmed", memory.status
    assert_equal memory.source_chat_message_id, @household.chat_sessions.find_by!(user: @owner).chat_messages.where(role: "user").last.id
    assert_not_includes memory.attributes.values.join(" "), "Remember that"

    post "/api/v1/mia/messages", params: {
      message: "What do you remember about me?", request_id: "remember-list-1"
    }, headers: auth_headers(@owner), as: :json

    assert_response :created
    answer = JSON.parse(response.body).dig("assistant_message", "content")
    assert_includes answer, "I prefer replies with one clear next step."
    assert_includes answer, "not financial truth"
    assert_no_difference("@household.household_memories.count") do
      post "/api/v1/mia/messages", params: {
        message: "What do you remember about me?", request_id: "remember-list-1"
      }, headers: auth_headers(@owner), as: :json
    end
    assert_response :created

    delete "/api/v1/mia/messages", headers: auth_headers(@owner)
    assert_response :no_content
    assert_nil memory.reload.source_chat_message_id
    assert_equal "I prefer replies with one clear next step.", memory.display_value
  end

  test "chat command keeps sensitive memory pending and respects paused personalization" do
    post "/api/v1/mia/messages", params: {
      message: "Remember that I have a private medical constraint.", request_id: "remember-sensitive-1"
    }, headers: auth_headers(@owner), as: :json
    assert_response :created
    memory = @household.household_memories.last
    assert_equal "sensitive", memory.sensitivity
    assert_equal "pending_confirmation", memory.status
    assert_includes JSON.parse(response.body).dig("assistant_message", "content"), "waiting for your confirmation"

    @household.household_memberships.find_by!(user: @owner).update!(mia_personalization_paused: true, mia_personalization_paused_at: Time.current)
    assert_no_difference("@household.household_memories.count") do
      post "/api/v1/mia/messages", params: {
        message: "Remember that I prefer short answers.", request_id: "remember-paused-1"
      }, headers: auth_headers(@owner), as: :json
    end
    assert_response :created
    assert_includes JSON.parse(response.body).dig("assistant_message", "content"), "Personalization is paused"
  end

  private

  def create_memory(display_value:, visibility:)
    @household.household_memories.create!(
      owner_user: @owner, category: "preference", status: "user_confirmed",
      sensitivity: "ordinary", visibility: visibility, source_kind: "manual_profile",
      display_value: display_value, confirmed_at: Time.current
    )
  end

  def create_user(email, role: "participant")
    User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: email, role: role, invitation_status: "accepted")
  end

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end
end
