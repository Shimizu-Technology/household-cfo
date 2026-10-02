# frozen_string_literal: true

require "digest"
require "json"

class CoachPersonaEvaluationCase < ApplicationRecord
  KINDS = %w[system custom].freeze

  belongs_to :coach_workspace
  belongs_to :coach_persona
  belongs_to :created_by_user, class_name: "User"
  belongs_to :retired_by_user, class_name: "User", optional: true
  has_many :evaluation_results, class_name: "CoachPersonaEvaluationResult", dependent: :restrict_with_exception

  validates :name, presence: true, length: { maximum: 120 }
  validates :case_kind, inclusion: { in: KINDS }
  validates :prompt, presence: true, length: { maximum: 2_000 }
  validates :system_key, length: { maximum: 80 }, allow_nil: true
  validates :case_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :request_key, length: { maximum: 100 }, allow_nil: true
  validates :request_fingerprint, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validates :retirement_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validate :workspace_matches_persona
  validate :creator_can_edit_persona, on: :create
  validate :assertions_are_valid
  validate :system_case_shape
  validate :retirement_is_coherent
  validate :retirement_digest_matches
  validate :sealed_fields_are_immutable, on: :update
  before_destroy :prevent_destroy_if_used_or_system

  def self.digest_for(attributes)
    value = attributes.respond_to?(:attributes) ? attributes.attributes : attributes.stringify_keys
    snapshot = {
      "system_key" => value["system_key"],
      "name" => value["name"],
      "case_kind" => value["case_kind"],
      "prompt" => value["prompt"],
      "assertions" => Mia::PhraseManifest.canonicalize(value["assertions"] || []),
      "required" => value["required"] == true,
      "request_key" => value["request_key"],
      "request_fingerprint" => value["request_fingerprint"]
    }
    Digest::SHA256.hexdigest(JSON.generate(snapshot).b)
  end

  def self.retirement_digest_for(case_id:, case_digest:, retired_by_user_id:, retired_at:)
    Digest::SHA256.hexdigest(JSON.generate({
      case_id: case_id,
      case_digest: case_digest,
      retired_by_user_id: retired_by_user_id,
      retired_at: retired_at.in_time_zone("UTC").iso8601(6)
    }).b)
  end

  def snapshot
    attributes.slice("id", "system_key", "name", "case_kind", "prompt", "assertions", "required", "case_digest")
  end

  def integrity_valid?
    case_digest.present? && ActiveSupport::SecurityUtils.secure_compare(case_digest, self.class.digest_for(self))
  end

  def retirement_integrity_valid?
    return [ retired_by_user_id, retired_at, retirement_digest ].all?(&:blank?) if active?
    return false if retired_by_user_id.blank? || retired_at.blank? || retirement_digest.blank?

    retirement_digest_valid?
  end

  def retire!(actor:)
    with_lock do
      raise ArgumentError, "Required system cases cannot be retired" if case_kind == "system"
      raise ArgumentError, "Only a workspace editor can retire an evaluation case" unless coach_workspace.allows?(actor, :edit)
      return self unless active?

      retired_at = Time.current
      digest = self.class.retirement_digest_for(
        case_id: id,
        case_digest: case_digest,
        retired_by_user_id: actor.id,
        retired_at: retired_at
      )
      update!(
        active: false,
        retired_by_user: actor,
        retired_at: retired_at,
        retirement_digest: digest
      )
      self
    end
  end

  private

  def workspace_matches_persona
    errors.add(:coach_workspace, "must match the persona workspace") if coach_persona && coach_workspace_id != coach_persona.coach_workspace_id
  end

  def creator_can_edit_persona
    return if coach_workspace&.allows?(created_by_user, :edit)

    errors.add(:created_by_user, "must be able to edit the persona workspace")
  end

  def assertions_are_valid
    Mia::PersonaRelease::AssertionEvaluator.validate!(assertions)
  rescue Mia::PersonaRelease::AssertionEvaluator::InvalidAssertion => error
    errors.add(:assertions, error.message)
  end

  def system_case_shape
    if case_kind == "system"
      errors.add(:system_key, "is required for a system case") if system_key.blank?
      errors.add(:required, "must be true for a system case") unless required?
      errors.add(:active, "must be true for a system case") unless active?
      errors.add(:request_key, "must be blank for a system case") if request_key.present? || request_fingerprint.present?
    else
      errors.add(:system_key, "must be blank for a custom case") if system_key.present?
      if request_key.blank? || request_fingerprint.blank?
        errors.add(:request_key, "and fingerprint are required for a custom case")
      end
    end
  end

  def retirement_is_coherent
    fields = [ retired_by_user, retired_at, retirement_digest ]
    if active?
      errors.add(:base, "active evaluation cases cannot have retirement evidence") if fields.any?(&:present?)
    elsif case_kind != "custom" || fields.any?(&:blank?)
      errors.add(:base, "retired custom cases require complete retirement evidence")
    end
  end

  def retirement_digest_matches
    return if active? || retired_at.blank? || retired_by_user_id.blank? || retirement_digest.blank?

    errors.add(:retirement_digest, "must match the retirement evidence") unless retirement_digest_valid?
  end

  def retirement_digest_valid?
    expected = self.class.retirement_digest_for(
      case_id: id,
      case_digest: case_digest,
      retired_by_user_id: retired_by_user_id,
      retired_at: retired_at
    )
    ActiveSupport::SecurityUtils.secure_compare(retirement_digest.to_s, expected)
  end

  def sealed_fields_are_immutable
    sealed = %w[
      coach_workspace_id coach_persona_id created_by_user_id system_key name case_kind prompt assertions required
      case_digest request_key request_fingerprint
    ]
    errors.add(:base, "evaluation case evidence is immutable") if changes_to_save.keys.intersect?(sealed)
    return if active_was

    retirement_fields = %w[active retired_by_user_id retired_at retirement_digest]
    errors.add(:base, "evaluation case retirement is immutable") if changes_to_save.keys.intersect?(retirement_fields)
  end

  def prevent_destroy_if_used_or_system
    return unless case_kind == "system" || evaluation_results.exists?

    errors.add(:base, "system and evaluated cases cannot be deleted")
    throw :abort
  end
end
