# frozen_string_literal: true

require "test_helper"

class CreateApprovedSourcePhrasePromotionsTest < ActiveSupport::TestCase
  test "audit tables expose required foreign keys unique indexes and checks" do
    connection = ActiveRecord::Base.connection
    %w[
      coach_phrase_proposals coach_phrase_attestations coach_persona_phrase_promotions
      coach_persona_version_phrase_artifacts
    ].each do |table|
      assert connection.data_source_exists?(table), "expected #{table}"
      assert connection.foreign_keys(table).any?, "expected foreign keys on #{table}"
    end

    assert connection.indexes(:coach_phrase_attestations).any? { |index| index.unique && index.columns == [ "coach_phrase_proposal_id" ] }
    assert connection.indexes(:coach_persona_phrase_promotions).any? { |index| index.unique && index.columns == %w[coach_persona_id artifact_id] }
    assert connection.indexes(:coach_persona_version_phrase_artifacts).any? { |index| index.unique && index.columns == %w[coach_persona_version_id position] }
    assert_includes connection.check_constraints(:coach_phrase_proposals).map(&:name), "phrase_proposals_digests_sha256"
    assert_includes connection.check_constraints(:coach_persona_versions).map(&:name), "coach_persona_versions_phrase_manifest_sha256"

    column = connection.columns(:coach_persona_versions).find { |candidate| candidate.name == "phrase_manifest_digest" }
    refute column.null
    assert_equal Mia::PhraseManifest.digest_for([]), column.default
  end
end
