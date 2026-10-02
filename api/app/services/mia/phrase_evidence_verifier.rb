# frozen_string_literal: true

require "digest"
require "tempfile"

module Mia
  class PhraseEvidenceVerifier
    class Error < StandardError
      attr_reader :code

      def initialize(message, code:)
        @code = code
        super(message)
      end
    end

    Result = Data.define(
      :phrase_payload, :evidence_locator, :evidence_start_byte, :evidence_end_byte,
      :source_checksum_sha256, :source_segment_digest, :phrase_digest,
      :approved_content_digest, :source_provenance_digest
    )

    def initialize(workspace:, source:, attempt:, candidate:, content_item_version:, phrase_payload:)
      @workspace = workspace
      @source = source
      @attempt = attempt
      @candidate = candidate
      @content_item_version = content_item_version
      @phrase_payload = PersonaSchema.normalize(phrase_payload).slice(*CoachPhraseProposal::PAYLOAD_KEYS)
    end

    def call
      verify_chain!
      validate_phrase_payload!

      Tempfile.create([ "approved-source-phrase", File.extname(source.filename) ]) do |file|
        file.binmode
        S3Service.download_to_io!(source.s3_key, file)
        file.flush
        ContentSources::UploadValidator.validate_metadata!(
          filename: source.filename,
          content_type: source.content_type,
          byte_size: File.size(file.path),
          checksum_sha256: source.checksum_sha256
        )
        ContentSources::UploadValidator.sniff!(path: file.path, filename: source.filename)
        checksum = Digest::SHA256.file(file.path).hexdigest
        secure_match!(checksum, source.checksum_sha256, "The private source checksum changed.", "phrase_source_checksum_mismatch")

        parsed = ContentSources::Parser.new.call(path: file.path, filename: source.filename)
        segment_number = Integer(candidate.evidence_locator.to_h["segment"], exception: false)
        segment = parsed.segments.find { |entry| entry.number == segment_number }
        raise Error.new("The approved source segment is no longer available.", code: "phrase_source_segment_missing") unless segment

        expected_locator = candidate.evidence_locator.to_h.stringify_keys.except("excerpt_digest")
        unless expected_locator == segment.locator
          raise Error.new("The approved source location no longer matches its review record.", code: "phrase_source_locator_mismatch")
        end

        phrase = phrase_payload.fetch("text").to_s
        unless content_item_version.content.to_s.b.include?(phrase.b)
          raise Error.new(
            "The phrase must exactly match wording in the current approved phrase item.",
            code: "phrase_approved_content_not_exact"
          )
        end
        start_byte = segment.text.b.index(phrase.b)
        unless start_byte
          raise Error.new("The phrase must exactly match wording in the approved source, including case and punctuation.", code: "phrase_source_not_exact")
        end

        verify_chain!
        Result.new(
          phrase_payload: phrase_payload,
          evidence_locator: segment.locator,
          evidence_start_byte: start_byte,
          evidence_end_byte: start_byte + phrase.b.bytesize,
          source_checksum_sha256: checksum,
          source_segment_digest: Digest::SHA256.hexdigest(segment.text.b),
          phrase_digest: Digest::SHA256.hexdigest(phrase.b),
          approved_content_digest: content_item_version.content_digest,
          source_provenance_digest: content_item_version.source_provenance.provenance_digest
        )
      end
    rescue ContentSources::Error => error
      raise Error.new("The private source could not be verified safely.", code: "phrase_source_#{error.code}")
    rescue Aws::S3::Errors::ServiceError, S3Service::MissingConfigurationError
      raise Error.new("The private source is unavailable for exact verification.", code: "phrase_source_unavailable")
    end

    private

    attr_reader :workspace, :source, :attempt, :candidate, :content_item_version, :phrase_payload

    def verify_chain!
      provenance = content_item_version.source_provenance
      item = content_item_version.coach_content_item
      valid = source.scope == "coach" && source.coach_workspace_id == workspace.id && source.source_available? &&
        attempt.coach_content_source_id == source.id && candidate.coach_content_source_id == source.id &&
        candidate.coach_content_source_attempt_id == attempt.id && candidate.status == "accepted" &&
        candidate.accepted_content_item_id == item.id && item.scope == "coach" && item.coach_workspace_id == workspace.id &&
        !item.archived? && item.current_approved_version_id == content_item_version.id &&
        content_item_version.kind == "phrase" && content_item_version.integrity_valid? &&
        provenance&.coach_content_source_id == source.id && provenance&.coach_content_source_attempt_id == attempt.id &&
        provenance&.coach_content_source_candidate_id == candidate.id
      raise Error.new("Choose an approved phrase item from this workspace and source.", code: "phrase_source_chain_invalid") unless valid
    end

    def validate_phrase_payload!
      unless phrase_payload.keys.sort == CoachPhraseProposal::PAYLOAD_KEYS.sort
        raise Error.new("Complete every phrase meaning, context, frequency, and caution field.", code: "phrase_payload_invalid")
      end

      PersonaSchema.validate_phrase_authoring_payload!(phrase_payload)
    rescue PersonaSchema::InvalidConfiguration => error
      raise Error.new(error.errors.first, code: "phrase_payload_invalid")
    end

    def secure_match!(actual, expected, message, code)
      valid = actual.bytesize == expected.to_s.bytesize && ActiveSupport::SecurityUtils.secure_compare(actual, expected.to_s)
      raise Error.new(message, code: code) unless valid
    end
  end
end
