# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class MiaApprovedContentRetrieverTest < ActiveSupport::TestCase
  include PersonaTestHelper

  test "retrieval is bounded deterministic deduplicated and restricted to exact published persona links" do
    coach = persona_user
    items = 8.times.map do |index|
      approved_content_item(
        owner: coach,
        title: "Emergency runway #{index}",
        content: "Emergency runway guidance #{index}. #{'x' * 1_100}"
      )
    end
    pack = published_content_pack(owner: coach, items: items)
    persona = create_persona(creator: coach)
    persona.replace_draft_content_pack_versions!([ pack.current_published_version ], actor: coach)
    runtime = Mia::RuntimePersona.new(publish_persona(persona, actor: coach))

    first = Mia::ApprovedContentRetriever.new(persona: runtime, query: "How much emergency runway do I need?").call
    second = Mia::ApprovedContentRetriever.new(persona: runtime, query: "How much emergency runway do I need?").call

    assert_equal first.map { |entry| entry.fetch(:item_version).id }, second.map { |entry| entry.fetch(:item_version).id }
    assert_operator first.length, :<=, 6
    assert_operator first.sum { |entry| entry.fetch(:content).bytesize }, :<=, 6_000
    assert_equal first.length, first.map { |entry| entry.fetch(:item_version).content_digest }.uniq.length

    unpublished = approved_content_item(owner: coach, title: "Not linked", content: "This must never be retrieved.")
    refute_includes first.map { |entry| entry.fetch(:item_version).id }, unpublished.current_approved_version_id
  end

  test "a locale label alone supplies no regional content" do
    coach = persona_user
    config = persona_configuration.deep_merge("culture" => { "locale_label" => "Guam" })
    persona = CoachPersona.create!(name: "Mia", draft_config: config, created_by_user: coach)
    runtime = Mia::RuntimePersona.new(publish_persona(persona, actor: coach))

    assert_empty Mia::ApprovedContentRetriever.new(persona: runtime, query: "How should this sound?").call
  end

  test "irrelevant content is excluded unless a coach explicitly marks it always on" do
    coach = persona_user
    irrelevant = approved_content_item(owner: coach, title: "Mortgage teaching", content: "Explain amortization only for mortgage questions.")
    always_on = approved_content_item(owner: coach, title: "Participant control", content: "Keep the participant in control of the decision.", always_on: true)
    pack = published_content_pack(owner: coach, items: [ irrelevant, always_on ])
    persona = create_persona(creator: coach)
    persona.replace_draft_content_pack_versions!([ pack.current_published_version ], actor: coach)
    runtime = Mia::RuntimePersona.new(publish_persona(persona, actor: coach))

    result = Mia::ApprovedContentRetriever.new(persona: runtime, query: "How should I plan groceries?").call

    assert_equal [ always_on.current_approved_version_id ], result.map { |entry| entry.fetch(:item_version).id }
    assert_equal "Always-on coach-approved context", result.first.fetch(:reason)
  end

  test "common coaching words alone do not make content relevant" do
    coach = persona_user
    common_only = approved_content_item(
      owner: coach,
      title: "General coaching note",
      content: "This guidance explains how the participant should make a household decision."
    )
    pack = published_content_pack(owner: coach, items: [ common_only ])
    persona = create_persona(creator: coach)
    persona.replace_draft_content_pack_versions!([ pack.current_published_version ], actor: coach)
    runtime = Mia::RuntimePersona.new(publish_persona(persona, actor: coach))

    result = Mia::ApprovedContentRetriever.new(
      persona: runtime,
      query: "How should the participant make this household decision?"
    ).call

    assert_empty result
  end

  test "a meaningful title term is deterministic and always-on content remains supplied" do
    coach = persona_user
    relevant = approved_content_item(
      owner: coach,
      title: "Mortgage amortization",
      content: "Compare principal and interest across the payoff schedule."
    )
    always_on = approved_content_item(
      owner: coach,
      title: "Participant control",
      content: "Keep the participant in control.",
      always_on: true
    )
    pack = published_content_pack(owner: coach, items: [ relevant, always_on ])
    persona = create_persona(creator: coach)
    persona.replace_draft_content_pack_versions!([ pack.current_published_version ], actor: coach)
    runtime = Mia::RuntimePersona.new(publish_persona(persona, actor: coach))

    first = Mia::ApprovedContentRetriever.new(persona: runtime, query: "How does amortization affect payoff?").call
    second = Mia::ApprovedContentRetriever.new(persona: runtime, query: "How does amortization affect payoff?").call

    assert_equal first.map { |entry| entry.fetch(:item_version).id }, second.map { |entry| entry.fetch(:item_version).id }
    assert_equal [ relevant.current_approved_version_id, always_on.current_approved_version_id ], first.map { |entry| entry.fetch(:item_version).id }
    assert_equal "Context supplied for: amortization, payoff", first.first.fetch(:reason)
  end

  test "coach packs precede platform references and exact versions remain stable" do
    admin = persona_user(role: "admin")
    coach = persona_user
    platform_item = approved_content_item(owner: admin, title: "Emergency reference", content: "Platform emergency reference.", kind: "finance_reference", scope: "platform")
    platform_pack = published_content_pack(owner: admin, items: [ platform_item ], name: "Platform finance", pack_kind: "finance_reference", scope: "platform")
    coach_item = approved_content_item(owner: coach, title: "Coach method", content: "Coach emergency method.")
    coach_pack = published_content_pack(owner: coach, items: [ coach_item ], name: "Coach method")
    persona = create_persona(creator: coach)
    persona.replace_draft_content_pack_versions!([ platform_pack.current_published_version, coach_pack.current_published_version ], actor: coach)
    runtime = Mia::RuntimePersona.new(publish_persona(persona, actor: coach))

    result = Mia::ApprovedContentRetriever.new(persona: runtime, query: "emergency method").call

    assert_equal coach_item.current_approved_version_id, result.first.fetch(:item_version).id
    assert_equal "Coach method", result.first.fetch(:pack_version).name
  end
end
