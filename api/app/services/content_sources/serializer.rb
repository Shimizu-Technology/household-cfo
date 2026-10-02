# frozen_string_literal: true

module ContentSources
  class Serializer
    def source(source, include_candidates: true, permissions: nil)
      current_attempt = source.current_attempt
      candidates = if include_candidates && current_attempt
        source.candidates.where(coach_content_source_attempt_id: current_attempt.id).order(:position)
      else
        []
      end
      payload = {
        id: source.id,
        scope: source.scope,
        filename: source.filename,
        content_type: source.content_type,
        byte_size: source.byte_size,
        checksum_sha256: source.checksum_sha256,
        status: source.status,
        generation: source.generation,
        source_available: source.source_available?,
        error: source.error_message,
        error_code: source.error_code,
        source_delete_error_code: source.source_delete_error_code,
        processing_metadata: safe_processing_metadata(source.processing_metadata),
        processed_at: source.processed_at,
        source_deleted_at: source.source_deleted_at,
        created_at: source.created_at,
        updated_at: source.updated_at,
        current_attempt: current_attempt && attempt(current_attempt),
        candidates: candidates.map { |candidate| candidate(candidate) }
      }
      payload[:permissions] = permissions if permissions
      payload
    end

    def candidate(candidate)
      {
        id: candidate.id,
        source_id: candidate.coach_content_source_id,
        position: candidate.position,
        status: candidate.status,
        title: candidate.title,
        kind: candidate.kind,
        content: candidate.content,
        topics: candidate.topics,
        evidence_locator: candidate.evidence_locator,
        evidence_excerpt: candidate.evidence_excerpt,
        revision: candidate.revision,
        digest: candidate.content_digest,
        safety_code: candidate.safety_code,
        accepted_content_item_id: candidate.accepted_content_item_id,
        reviewed_at: candidate.reviewed_at,
        updated_at: candidate.updated_at
      }
    end

    def attempt(attempt)
      {
        id: attempt.id,
        generation: attempt.generation,
        status: attempt.status,
        provider: attempt.provider,
        model: attempt.model,
        prompt_version: attempt.prompt_version,
        schema_version: attempt.schema_version,
        error: attempt.error_message,
        error_code: attempt.error_code,
        started_at: attempt.started_at,
        completed_at: attempt.completed_at,
        metadata: attempt.metadata.to_h.slice("usage", "finish_reason", "provider", "candidate_count")
      }
    end

    private

    def safe_processing_metadata(metadata)
      metadata.to_h.slice("format", "page_count", "paragraph_count", "line_count", "cue_count", "character_count", "segment_count", "candidate_count")
    end
  end
end
