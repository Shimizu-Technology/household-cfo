# frozen_string_literal: true

require "digest"
require "json"

class CoachPersonaEvaluationRun < ApplicationRecord
  STATUSES = %w[pending running passed failed error].freeze

  belongs_to :release_candidate, class_name: "CoachPersonaReleaseCandidate",
    foreign_key: :coach_persona_release_candidate_id
  belongs_to :requested_by_user, class_name: "User"
  has_many :results, class_name: "CoachPersonaEvaluationResult", dependent: :restrict_with_exception
  has_one :approval, class_name: "CoachPersonaEvaluationApproval", dependent: :restrict_with_exception
  has_many :persona_versions, class_name: "CoachPersonaVersion", dependent: :restrict_with_exception

  validates :status, inclusion: { in: STATUSES }
  validates :adapter_kind, presence: true, length: { maximum: 80 }
  validates :cases_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :run_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validate :lifecycle_is_coherent
  validate :requester_can_edit_persona
  validate :sealed_run_is_immutable, on: :update
  before_destroy :prevent_destroy

  def self.digest_for(run:, results:)
    Digest::SHA256.hexdigest(JSON.generate(Mia::PhraseManifest.canonicalize({
      candidate_digest: run.release_candidate.manifest_digest,
      requested_by_user_id: run.requested_by_user_id,
      adapter_kind: run.adapter_kind,
      cases_digest: run.cases_digest,
      status: run.status,
      started_at: run.started_at&.in_time_zone("UTC")&.iso8601(6),
      completed_at: run.completed_at&.in_time_zone("UTC")&.iso8601(6),
      results: results.sort_by(&:coach_persona_evaluation_case_id).map(&:result_digest)
    })).b)
  end

  def passed_and_valid?
    return false unless status == "passed" && run_digest.present? && completed_at.present?

    entries = results.includes(:evaluation_case).to_a
    return false if entries.empty? || entries.any? { |result| !result.integrity_valid? || result.status != "passed" || result.fallback_only? }
    evaluated_cases_digest = Digest::SHA256.hexdigest(JSON.generate(
      entries.sort_by(&:coach_persona_evaluation_case_id).map { |entry| entry.evaluation_case.case_digest }
    ).b)
    return false unless ActiveSupport::SecurityUtils.secure_compare(cases_digest, evaluated_cases_digest)
    ActiveSupport::SecurityUtils.secure_compare(run_digest, self.class.digest_for(run: self, results: entries))
  end

  def current_suite_pass?
    return false unless passed_and_valid?

    entries = results.includes(:evaluation_case).to_a
    evaluated_ids = entries.map(&:coach_persona_evaluation_case_id)
    active_ids = release_candidate.coach_persona.evaluation_cases.where(active: true).pluck(:id)
    required_keys = Mia::PersonaRelease::SystemCases::DEFINITIONS.pluck(:system_key)
    evaluated_keys = entries.filter_map { |entry| entry.evaluation_case.system_key }
    active_ids.sort == evaluated_ids.sort && (required_keys - evaluated_keys).empty?
  end

  private

  def lifecycle_is_coherent
    terminal = status.in?(%w[passed failed error])
    errors.add(:completed_at, "must match run status") unless terminal == completed_at.present?
    errors.add(:run_digest, "must be present only for a completed run") unless terminal == run_digest.present?
    errors.add(:started_at, "is required after a run starts") if status != "pending" && started_at.blank?
  end

  def requester_can_edit_persona
    workspace = release_candidate&.coach_persona&.coach_workspace
    return if workspace&.allows?(requested_by_user, :edit)

    errors.add(:requested_by_user, "must be able to edit the persona workspace")
  end

  def sealed_run_is_immutable
    return unless status_was.in?(%w[passed failed error])

    errors.add(:base, "completed evaluation runs are immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "evaluation runs cannot be deleted")
    throw :abort
  end
end
