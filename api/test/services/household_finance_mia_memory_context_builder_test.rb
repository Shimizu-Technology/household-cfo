require "test_helper"

class HouseholdFinanceMiaMemoryContextBuilderTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "memory-context-#{SecureRandom.hex(4)}", email: "memory-context-#{SecureRandom.hex(4)}@example.com", role: "participant")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
  end

  test "context includes only bounded confirmed visible unexpired memories" do
    22.times do |index|
      create_memory("Preference #{index}", status: "user_confirmed")
    end
    create_memory("Waiting", status: "pending_confirmation")
    create_memory("Expired", status: "user_confirmed", expires_at: 1.minute.ago)

    context = HouseholdFinance::MiaMemoryContextBuilder.new(@household, user: @user).call

    assert_equal "user_curated_personalization", context.fetch(:context_type)
    assert_equal 20, context.fetch(:memories).length
    assert_not context.fetch(:paused)
    assert_not_includes context.fetch(:memories).pluck(:value), "Waiting"
    assert_not_includes context.fetch(:memories).pluck(:value), "Expired"
    assert_includes context.fetch(:rule), "never financial truth"
  end

  test "private entries from another participant do not enter context" do
    partner = User.create!(clerk_id: "memory-partner-#{SecureRandom.hex(4)}", email: "memory-partner-#{SecureRandom.hex(4)}@example.com", role: "participant")
    @household.household_memberships.create!(user: partner, role: "partner")
    create_memory("Partner private", status: "user_confirmed", owner: partner)

    values = HouseholdFinance::MiaMemoryContextBuilder.new(@household, user: @user).call.fetch(:memories).pluck(:value)
    assert_not_includes values, "Partner private"
  end

  test "context has a deterministic aggregate byte budget and does not trigger narrator packet fallback" do
    20.times do |index|
      create_memory("#{index}: #{('careful coaching context ' * 18).strip}", status: "user_confirmed")
    end

    context = HouseholdFinance::MiaMemoryContextBuilder.new(@household, user: @user).call
    assert_operator JSON.generate(context).bytesize, :<=, HouseholdFinance::MiaMemoryContextBuilder::MAX_CONTEXT_BYTES
    assert_operator context.fetch(:memories).length, :>, 0
    assert_operator context.fetch(:memories).length, :<, HouseholdFinance::MiaMemoryContextBuilder::MAX_MEMORIES

    packet = HouseholdFinance::MiaAnswerPacketBuilder.new(
      kind: "coaching",
      fallback_response: "Use the approved plan and take one next step.",
      write_state: "no_write",
      conversation_context: {
        personalization_memory: context,
        active_topic: { schema_version: 2, type: "coaching", title: "Current plan" },
        rolling_summary: "s" * 10_500
      }
    ).call
    serialized = HouseholdFinance::MiaNarrator.new(
      user_message: "What should I do?",
      answer_packet: packet,
      api_key: ""
    ).send(:packet_json)
    parsed = JSON.parse(serialized)
    assert_operator serialized.bytesize, :<=, HouseholdFinance::MiaNarrator::MAX_PACKET_BYTES
    assert parsed.key?("conversation_state")
    assert_equal 10_500, parsed.dig("conversation_state", "older_summary").length
    assert_operator Array(parsed.dig("personalization_memory", "memories")).length, :<, context.fetch(:memories).length
  end

  private

  def create_memory(value, status:, expires_at: nil, owner: @user)
    @household.household_memories.create!(
      owner_user: owner, category: "preference", status: status, sensitivity: "ordinary",
      visibility: "private", source_kind: "manual_profile", display_value: value,
      confirmed_at: status == "user_confirmed" ? Time.current : nil, expires_at: expires_at
    )
  end
end
