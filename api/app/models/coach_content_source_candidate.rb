# frozen_string_literal: true

require "digest"

class CoachContentSourceCandidate < ApplicationRecord
  class ReviewConflict < StandardError; end

  STATUSES = %w[proposed accepted rejected superseded].freeze

  belongs_to :coach_content_source
  belongs_to :coach_content_source_attempt
  belongs_to :reviewed_by_user, class_name: "User", optional: true
  belongs_to :accepted_content_item, class_name: "CoachContentItem", optional: true
  has_one :draft_provenance, class_name: "CoachContentItemDraftProvenance", dependent: :restrict_with_exception
  has_many :version_provenances, class_name: "CoachContentItemVersionProvenance", dependent: :restrict_with_exception

  normalizes :title, with: ->(value) { value.to_s.squish }
  normalizes :content, with: ->(value) { value.to_s.strip }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than: 30 }, uniqueness: { scope: :coach_content_source_attempt_id }
  validates :status, inclusion: { in: STATUSES }
  validates :title, presence: true, length: { maximum: 160 }
  validates :kind, inclusion: { in: CoachContentItem::KINDS }
  validates :content, presence: true, length: { maximum: 10_000 }
  validates :topics, length: { maximum: 12 }
  validates :evidence_excerpt, presence: true, length: { maximum: 1_000 }
  validates :content_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :original_proposal_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :revision, numericality: { only_integer: true, greater_than: 0 }
  validate :attempt_belongs_to_source
  validate :digest_matches_review_content
  validate :review_state_is_consistent
  validate :content_has_bounded_bytes
  validate :topics_are_bounded_strings
  validate :evidence_locator_is_valid
  validate :candidate_identity_is_immutable, on: :update
  before_validation :normalize_review_fields
  before_validation :capture_original_proposal_digest, on: :create

  def self.digest_for(title:, kind:, content:, topics: [])
    Digest::SHA256.hexdigest(JSON.generate({
      title: title.to_s.squish,
      kind: kind.to_s,
      content: content.to_s.strip,
      topics: Array(topics).map { |topic| topic.to_s.squish.downcase }.reject(&:blank?).uniq.sort,
      always_on: false
    }).b)
  end

  def review_digest
    self.class.digest_for(title: title, kind: kind, content: content, topics: topics)
  end

  def update_review!(attributes, actor:, expected_revision:, expected_digest:)
    violation = nil
    source = coach_content_source
    source.with_lock do
      with_lock do
        verify_cas!(expected_revision, expected_digest)
        raise ArgumentError, "Only proposed candidates can be edited" unless status == "proposed"
        raise ArgumentError, "Not authorized for this candidate" unless manageable_by?(actor)
        raise ArgumentError, "This source generation is no longer current" unless current_generation_locked?(source)

        assign_attributes(attributes.slice(:title, :kind, :content, :topics))
        self.topics = normalize_topics(topics)
        self.content_digest = review_digest
        self.revision += 1
        begin
          Mia::ContentSafetyValidator.validate!(title: title, content: content, topics: topics)
          self.safety_code = nil
        rescue Mia::ContentSafetyValidator::UnsafeContent => error
          self.safety_code = error.code
          violation = error
        end
        save!
      end
    end
    raise violation if violation

    self
  end

  def accept!(actor:, expected_revision:, expected_digest:)
    violation = nil
    created_item = nil
    source = coach_content_source
    source.with_lock do
      with_lock do
        verify_cas!(expected_revision, expected_digest)
        raise ArgumentError, "Not authorized for this candidate" unless manageable_by?(actor)
        return accepted_content_item if status == "accepted" && accepted_content_item.present?
        raise ArgumentError, "Only proposed candidates can be accepted" unless status == "proposed"
        raise ArgumentError, "This source generation is no longer current" unless current_generation_locked?(source)

        begin
          Mia::ContentSafetyValidator.validate!(title: title, content: content, topics: topics)
        rescue Mia::ContentSafetyValidator::UnsafeContent => error
          self.safety_code = error.code
          save!(validate: false)
          violation = error
        end

        unless violation
          created_item = CoachContentItem.create!(
            title: title,
            scope: source.scope,
            kind: kind,
            draft_content: content,
            draft_always_on: false,
            created_by_user: source.created_by_user
          )
          accepted_at = Time.current
          update!(
            status: "accepted",
            safety_code: nil,
            reviewed_by_user: actor,
            reviewed_at: accepted_at,
            accepted_content_item: created_item
          )
          CoachContentItemDraftProvenance.create_from_candidate!(candidate: self, item: created_item)
        end
      end
    end
    raise violation if violation

    created_item
  end

  def reject!(actor:, expected_revision:, expected_digest:)
    source = coach_content_source
    source.with_lock do
      with_lock do
        verify_cas!(expected_revision, expected_digest)
        raise ArgumentError, "Not authorized for this candidate" unless manageable_by?(actor)
        return self if status == "rejected"
        raise ArgumentError, "Only proposed candidates can be rejected" unless status == "proposed"
        raise ArgumentError, "This source generation is no longer current" unless current_generation_locked?(source)

        update!(status: "rejected", reviewed_by_user: actor, reviewed_at: Time.current)
      end
    end
    self
  end

  private

  def manageable_by?(actor)
    actor&.admin? || (coach_content_source.scope == "coach" && coach_content_source.created_by_user_id == actor&.id)
  end

  def verify_cas!(expected_revision, expected_digest)
    valid = Integer(expected_revision, exception: false) == revision && expected_digest.present? &&
      ActiveSupport::SecurityUtils.secure_compare(expected_digest.to_s, content_digest)
    raise ReviewConflict, "The candidate changed; reload it before continuing." unless valid
  end

  def current_generation_locked?(source)
    source.status == "needs_review" && source.current_attempt_id == coach_content_source_attempt_id &&
      source.generation == coach_content_source_attempt.generation
  end

  def normalize_topics(value)
    Array(value).filter_map { |topic| topic.to_s.unicode_normalize(:nfkc).squish.downcase.presence }.uniq.first(12)
  end

  def attempt_belongs_to_source
    return if coach_content_source_attempt.nil? || coach_content_source_attempt.coach_content_source_id == coach_content_source_id

    errors.add(:coach_content_source_attempt, "must belong to this source")
  end

  def digest_matches_review_content
    errors.add(:content_digest, "must match the review content") unless content_digest.present? && ActiveSupport::SecurityUtils.secure_compare(content_digest, review_digest)
  end

  def review_state_is_consistent
    errors.add(:accepted_content_item, "is required for an accepted candidate") if status == "accepted" && accepted_content_item.nil?
    errors.add(:accepted_content_item, "is only allowed for an accepted candidate") if status != "accepted" && accepted_content_item.present?
  end

  def content_has_bounded_bytes
    errors.add(:content, "is too large (maximum is 12,000 bytes)") if content.to_s.bytesize > 12_000
    errors.add(:evidence_excerpt, "is too large (maximum is 1,200 bytes)") if evidence_excerpt.to_s.bytesize > 1_200
  end

  def normalize_review_fields
    self.topics = normalize_topics(topics)
    self.evidence_locator = evidence_locator.to_h.stringify_keys.slice(
      "type", "segment", "page_start", "page_end", "paragraph_start", "paragraph_end",
      "line_start", "line_end", "cue_start", "cue_end", "time_start", "time_end", "excerpt_digest"
    ) if evidence_locator.respond_to?(:to_h)
  end

  def capture_original_proposal_digest
    self.original_proposal_digest ||= review_digest
  end

  def topics_are_bounded_strings
    unless topics.is_a?(Array) && topics.all? { |topic| topic.is_a?(String) && topic.length.between?(1, 80) && topic.bytesize <= 240 }
      errors.add(:topics, "must contain at most 12 short text labels")
    end
  end

  def evidence_locator_is_valid
    locator = evidence_locator
    unless locator.is_a?(Hash) && locator["type"].to_s.in?(%w[pdf docx text vtt srt]) &&
        locator["segment"].is_a?(Integer) && locator["segment"].between?(1, 6) &&
        locator["excerpt_digest"].to_s.match?(/\A[0-9a-f]{64}\z/)
      errors.add(:evidence_locator, "must contain a safe source location")
      return
    end

    numeric_keys = %w[page_start page_end paragraph_start paragraph_end line_start line_end cue_start cue_end]
    errors.add(:evidence_locator, "contains an invalid source range") unless numeric_keys.filter_map { |key| locator[key] }.all? { |value| value.is_a?(Integer) && value.positive? && value <= 1_000_000 }
  end

  def candidate_identity_is_immutable
    identity_fields = %w[coach_content_source_id coach_content_source_attempt_id position evidence_locator evidence_excerpt original_proposal_digest]
    errors.add(:base, "candidate source identity is immutable") if changes_to_save.keys.intersect?(identity_fields)
    return if status_was == "proposed"

    errors.add(:base, "reviewed candidates are immutable") if has_changes_to_save?
  end
end
