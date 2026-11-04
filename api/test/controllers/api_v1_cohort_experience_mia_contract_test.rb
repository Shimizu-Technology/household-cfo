# frozen_string_literal: true

require "test_helper"

class ApiV1CohortExperienceMiaContractTest < ActionDispatch::IntegrationTest
  setup do
    travel_to HouseholdFinance::MiaEvalHousehold.eval_time
    @user, @household = HouseholdFinance::MiaEvalHousehold.create!
    coach = User.create!(clerk_id: "module-coach", email: "module-coach@example.invalid", role: "coach", invitation_status: "accepted")
    cohort = Cohort.create!(name: "Hidden destinations", status: "active", created_by_user: coach)
    cohort.cohort_memberships.create!(user: @user, role: "participant")
    configuration = cohort.cohort_experience_configuration
    config = CohortExperience::Schema.upgrade(configuration.draft_config)
    config["optional_modules"] = CohortExperience::Schema::CONFIGURABLE_MODULES.index_with(false)
    configuration.update!(draft_config: config, last_edited_by_user: coach)
    publisher = CohortExperience::Publisher.new(configuration: configuration, actor: coach)
    digest = publisher.preview!(expected_draft_revision: configuration.draft_revision)
    publisher.publish!(expected_preview_digest: digest, expected_draft_revision: configuration.draft_revision, expected_current_version_id: nil)
    CohortReleases::LegacyReconciler.new(scope: Cohort.where(id: cohort.id)).call
    cohort.update!(active_cohort_release: cohort.cohort_releases.sole)
  end

  teardown { travel_back }

  test "generic model gets capabilities and disabled recommendations cannot reach saved replies" do
    calls = []
    with_model_reply("Open Wealth to compare your choices.", calls) do
      post_message("ok last thing what should i focus on this week")
    end
    assert_response :created
    generic = calls.find { |payload| payload.fetch("messages").any? { |item| item["content"].include?("MODULE_CAPABILITIES_JSON") } }
    assert generic, "the current reply model must receive the capability system rule"
    system = generic.fetch("messages").select { |item| item["role"] == "system" }.pluck("content").join("\n")
    assert_includes system, '"enabled":["home","ask_mia"]'
    assert_includes system, '"disabled":["review","budget","profile","wealth","cfo_filter","optionality","statements"]'
    content = response.parsed_body.dig("assistant_message", "content")
    refute_includes content, "Open Wealth"
    assert_includes content, "here in chat"
    assert_equal content, ChatMessage.find(response.parsed_body.dig("assistant_message", "id")).content
  end

  test "structured narrator receives the same module rule and packet as generic replies" do
    calls = []
    with_model_reply("Open Budget to check your plan.", calls) do
      post_message("How much is planned for Dining Out this month?")
    end
    assert_response :created
    narrated = calls.find { |payload| payload.fetch("messages").any? { |item| item["content"].include?("ANSWER_PACKET_JSON") } }
    assert narrated, "budget replies must use the existing structured narrator"
    messages = narrated.fetch("messages")
    assert messages.any? { |item| item["role"] == "system" && item["content"].include?("MODULE_CAPABILITIES_JSON") }
    assert messages.any? { |item| item["content"].include?('"available_product_modules"') }
    refute_includes response.parsed_body.dig("assistant_message", "content"), "Open Budget"
  end

  private

  def post_message(message)
    post "/api/v1/mia/messages", params: { message: message, year: 2026, month: 7 },
      headers: { "Authorization" => "Bearer test_token_#{@user.id}" }, as: :json
  end

  def with_model_reply(content, calls)
    previous_key = ENV["OPENROUTER_API_KEY"]
    ENV["OPENROUTER_API_KEY"] = "test-key"
    singleton = OpenRouterConnection.singleton_class
    original = singleton.instance_method(:start)
    singleton.define_method(:start) do |*_args, **_options, &block|
      http = Object.new
      http.define_singleton_method(:request) do |request|
        calls << JSON.parse(request.body)
        Net::HTTPOK.new("1.1", "200", "OK").tap do |response|
          response.instance_variable_set(:@read, true)
          response.body = JSON.generate(id: "module-contract-test", model: "anthropic/claude-sonnet-5.5", choices: [ { message: { content: content } } ])
        end
      end
      block.call(http)
    end
    yield
  ensure
    singleton.send(:remove_method, :start)
    singleton.define_method(:start, original)
    previous_key ? ENV["OPENROUTER_API_KEY"] = previous_key : ENV.delete("OPENROUTER_API_KEY")
  end
end
