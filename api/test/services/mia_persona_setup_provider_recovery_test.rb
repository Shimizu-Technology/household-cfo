# frozen_string_literal: true

require "test_helper"

class MiaPersonaSetupProviderRecoveryTest < ActiveSupport::TestCase
  GOOD = { supported: true, speaker: "hers", identity: false, harmful: false }.freeze
  PROPOSAL = { assistant_message: "Review these suggestions. Nothing has been saved.", operations: [] }.freeze

  test "proposal extracts one JSON object from prose fences and tool-like markup" do
    [ "Here is the proposal.\n<invoke name=\"x\">\n#{PROPOSAL.to_json}\n</invoke>", "```json\n#{PROPOSAL.to_json}\n```" ].each do |content|
      result = resolver([ response(content) ]).call(context: {}, user_message: "I welcome questions.")
      assert_equal [], result.operations
    end
  end

  test "proposal retries malformed replies and transport errors once with unchanged input" do
    [ response("not JSON"), response({ operations: [] }.to_json), Net::ReadTimeout.new, EOFError.new ].each do |failure|
      requests = []
      result = resolver([ failure, response(PROPOSAL.to_json) ], requests).call(context: {}, user_message: "I welcome questions.")
      assert_equal [], result.operations
      assert_equal 2, requests.length
      assert_equal requests.first, requests.last
    end
  end

  test "proposal stops after two malformed replies and does not retry rate limits or wrong models" do
    requests = []
    assert_raises(Mia::PersonaSetup::ProposalResolver::Error) { resolver([ response("bad"), response("bad") ], requests).call(context: {}, user_message: "Hello") }
    assert_equal 2, requests.length
    [ Net::HTTPTooManyRequests.new("1.1", "429", "Too many"), response(PROPOSAL.to_json, model: "wrong") ].each do |failure|
      requests = []
      assert_raises(Mia::PersonaSetup::ProposalResolver::Error) { resolver([ failure ], requests).call(context: {}, user_message: "Hello") }
      assert_equal 1, requests.length
    end
  end

  test "guard extracts JSON and retries malformed verdicts and transport once but never refusals" do
    [ "prose <invoke>#{GOOD.to_json}</invoke>", "```json\n#{GOOD.to_json}\n```", "bad", {}.to_json, Net::ReadTimeout.new, EOFError.new, GOOD.merge(identity: true).to_json ].each do |first|
      calls = 0
      guard = Mia::PersonaSetup::ProposalGuard.new(user_message: "I welcome questions.", operation: {}, current_value: nil, api_key: "test")
      guard.define_singleton_method(:classify) do
        calls += 1
        raise first if first.is_a?(Exception) && calls == 1
        calls == 1 ? first : GOOD.to_json
      end
      result = guard.call
      refused = first == GOOD.merge(identity: true).to_json
      assert_equal !refused, result.allowed?, first.inspect
      expected = [ "bad", "{}" ].include?(first) || first.is_a?(Exception) ? 2 : 1
      assert_equal expected, calls, first.inspect
    end
  end

  test "guard rejects ambiguous multiple JSON objects without selecting the favorable verdict" do
    guard = Mia::PersonaSetup::ProposalGuard.new(user_message: "Hello", operation: {}, current_value: nil, api_key: "test")
    calls = 0
    guard.define_singleton_method(:classify) { calls += 1; "#{GOOD.to_json}\n#{GOOD.merge(identity: true).to_json}" }
    refute guard.call.allowed?
    assert_equal 2, calls
  end

  test "proposal separates client quotations bans and adopted coaching into individual ideas" do
    prompt = resolver([]).payload_for(context: {}, user_message: "Hello")[:messages].pluck(:content).join(" ")
    assert_includes prompt, "Each new coaching list item must contain one adopted idea"
    assert_includes prompt, 'Do not say "Give up." Ask what would help.'
    assert_includes prompt, "I no longer lecture; I ask questions instead."
    assert_includes prompt, "Never copy a client line"
  end

  test "guard contract distinguishes personal words from group speech and preserves conditions and nouns" do
    prompt = Mia::PersonaSetup::ProposalGuard::SYSTEM_PROMPT
    assert_includes prompt, "Her own quoted saying is hers"
    assert_includes prompt, "on Guam"
    assert_includes prompt, 'Before they sign "Yes." wait 2 days.'
    assert_includes prompt, '"savings" and "saving"'
  end

  private

  def response(content, model: "exact/model")
    Net::HTTPOK.new("1.1", "200", "OK").tap do |r|
      r.instance_variable_set(:@read, true)
      r.body = { model: model, choices: [ { finish_reason: "stop", message: { content: content } } ] }.to_json
    end
  end

  def resolver(replies, requests = [])
    transport = lambda do |payload|
      requests << payload
      value = replies.shift
      raise value if value.is_a?(Exception)
      value
    end
    Mia::PersonaSetup::ProposalResolver.new(api_key: "test", model: "exact/model", transport: transport)
  end
end
