# frozen_string_literal: true

require "digest"
require "json"

class CoachPersonaEvaluationResult < ApplicationRecord
  STATUSES = %w[passed failed error].freeze

  belongs_to :evaluation_run, class_name: "CoachPersonaEvaluationRun",
    foreign_key: :coach_persona_evaluation_run_id
  belongs_to :evaluation_case, class_name: "CoachPersonaEvaluationCase",
    foreign_key: :coach_persona_evaluation_case_id

  validates :status, inclusion: { in: STATUSES }
  validates :output, length: { maximum: 20_000 }
  validates :result_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :case_matches_run
  validate :snapshot_matches_case
  validate :digest_matches_snapshot
  validate :immutable_record, on: :update
  before_destroy :prevent_destroy

  def self.digest_for(attributes)
    value = attributes.respond_to?(:attributes) ? attributes.attributes : attributes.stringify_keys
    Digest::SHA256.hexdigest(JSON.generate(Mia::PhraseManifest.canonicalize({
      case_id: value["coach_persona_evaluation_case_id"],
      status: value["status"],
      case_snapshot: value["case_snapshot"],
      output: value["output"],
      adapter_metadata: value["adapter_metadata"],
      assertion_results: value["assertion_results"],
      fallback_only: value["fallback_only"] == true
    })).b)
  end

  def integrity_valid?
    evaluation_case&.integrity_valid? && case_snapshot == evaluation_case.snapshot &&
      result_digest.present? && ActiveSupport::SecurityUtils.secure_compare(result_digest, self.class.digest_for(self))
  end

  private

  def case_matches_run
    candidate = evaluation_run&.release_candidate
    return if candidate && evaluation_case&.coach_persona_id == candidate.coach_persona_id &&
      evaluation_case.coach_workspace_id == candidate.coach_persona.coach_workspace_id

    errors.add(:evaluation_case, "must belong to the evaluated persona")
  end

  def snapshot_matches_case
    errors.add(:case_snapshot, "must match the sealed case") unless evaluation_case && case_snapshot == evaluation_case.snapshot
  end

  def digest_matches_snapshot
    expected = self.class.digest_for(self)
    errors.add(:result_digest, "must match the result") unless result_digest.present? && ActiveSupport::SecurityUtils.secure_compare(result_digest, expected)
  end

  def immutable_record
    errors.add(:base, "evaluation results are immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "evaluation results cannot be deleted")
    throw :abort
  end
end
