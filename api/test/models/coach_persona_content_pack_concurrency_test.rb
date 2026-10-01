# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class CoachPersonaContentPackConcurrencyTest < ActiveSupport::TestCase
  include PersonaTestHelper

  self.use_transactional_tests = false

  test "only one concurrent source selection can use the same persona draft revision" do
    coach = persona_user
    item = approved_content_item(owner: coach, title: "Concurrent source")
    pack = published_content_pack(owner: coach, items: [ item ])
    persona = create_persona(creator: coach)
    remember_records(coach:, item:, pack:, persona:)
    expected_revision = persona.draft_revision
    ready = Queue.new
    start = Queue.new
    results = Queue.new

    threads = 2.times.map do
      Thread.new do
        Thread.current.report_on_exception = false
        ActiveRecord::Base.connection_pool.with_connection do
          candidate = CoachPersona.find(persona.id)
          version = CoachContentPackVersion.find(pack.current_published_version_id)
          ready << true
          start.pop
          begin
            candidate.replace_draft_content_pack_versions!(
              [ version ],
              actor: User.find(coach.id),
              expected_draft_revision: expected_revision
            )
            results << :saved
          rescue CoachPersona::DraftConflict
            results << :conflict
          rescue StandardError => error
            results << [ :error, error.class.name, error.message ]
          end
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.each(&:join)

    outcomes = 2.times.map { results.pop }
    assert_equal 1, outcomes.count(:saved), -> { "unexpected concurrent outcomes: #{outcomes.inspect}" }
    assert_equal 1, outcomes.count(:conflict), -> { "unexpected concurrent outcomes: #{outcomes.inspect}" }
    assert_equal expected_revision + 1, persona.reload.draft_revision
    assert_equal [ pack.current_published_version_id ], persona.draft_content_pack_version_ids
  ensure
    cleanup_records
  end

  private

  def remember_records(coach:, item:, pack:, persona:)
    @record_ids = { coach: coach.id, item: item.id, pack: pack.id, persona: persona.id }
  end

  def cleanup_records
    return unless @record_ids

    CoachPersonaDraftContentPack.where(coach_persona_id: @record_ids[:persona]).delete_all
    CoachPersona.where(id: @record_ids[:persona]).update_all(current_published_version_id: nil)
    CoachPersona.where(id: @record_ids[:persona]).delete_all
    CoachContentPackDraftEntry.where(coach_content_pack_id: @record_ids[:pack]).delete_all
    version_ids = CoachContentPackVersion.where(coach_content_pack_id: @record_ids[:pack]).pluck(:id)
    CoachContentPackVersionEntry.where(coach_content_pack_version_id: version_ids).delete_all
    CoachContentPack.where(id: @record_ids[:pack]).update_all(current_published_version_id: nil)
    CoachContentPackVersion.where(id: version_ids).delete_all
    CoachContentPack.where(id: @record_ids[:pack]).delete_all
    CoachContentItem.where(id: @record_ids[:item]).update_all(current_approved_version_id: nil)
    CoachContentItemVersion.where(coach_content_item_id: @record_ids[:item]).delete_all
    CoachContentItem.where(id: @record_ids[:item]).delete_all
    User.where(id: @record_ids[:coach]).delete_all
  end
end
