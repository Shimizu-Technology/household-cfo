# frozen_string_literal: true

# The one place that decides which OpenRouter models Household CFO uses.
#
# AI_MODEL drives every text call: Mia intent and narration, demo/persona
# release chat, document extraction, content-source proposals, and persona
# setup. AI_TRANSCRIPTION_MODEL drives voice transcription. The older
# OPENROUTER_MODEL / OPENROUTER_TRANSCRIPTION_MODEL names still work as
# fallbacks so an existing deployment keeps its current model until AI_MODEL
# is set.
module AiModels
  DEFAULT_TEXT_MODEL = "anthropic/claude-sonnet-5.5"
  DEFAULT_TRANSCRIPTION_MODEL = "openai/whisper-large-v3"
  TEXT_ENV_KEYS = %w[AI_MODEL OPENROUTER_MODEL].freeze
  TRANSCRIPTION_ENV_KEYS = %w[AI_TRANSCRIPTION_MODEL OPENROUTER_TRANSCRIPTION_MODEL].freeze
  # Per-task overrides that no longer have any effect. Reported at boot so a
  # stale setting is noticed instead of silently ignored.
  RETIRED_ENV_KEYS = %w[
    OPENROUTER_MIA_MODEL OPENROUTER_MIA_INTENT_MODEL OPENROUTER_EXTRACTION_MODEL
    OPENROUTER_CONTENT_SOURCE_MODEL OPENROUTER_PERSONA_SETUP_MODEL MIA_TRANSCRIPTION_MODEL
  ].freeze

  module_function

  def text(env = ENV)
    first_present(env, TEXT_ENV_KEYS) || DEFAULT_TEXT_MODEL
  end

  def transcription(env = ENV)
    first_present(env, TRANSCRIPTION_ENV_KEYS) || DEFAULT_TRANSCRIPTION_MODEL
  end

  # Reasoning tokens count against max_tokens. Without this allowance a model that
  # always reasons can spend a short reply budget thinking and return nothing.
  REASONING_ALLOWANCE_TOKENS = 1_024

  # Reasoning settings for conversational calls that must stay quick.
  # Claude and Gemini 3+ models always reason (it cannot be turned off), so ask
  # for the lightest effort. Gemini 2.5 Flash does not reason unless asked, and
  # asking would add thinking tokens and latency, so leave it alone.
  def chat_reasoning(model)
    { effort: "low" } if always_reasons?(model)
  end

  # max_tokens for a reply of about reply_tokens, plus room to reason when the
  # model always does.
  def output_budget(model, reply_tokens)
    always_reasons?(model) ? reply_tokens + REASONING_ALLOWANCE_TOKENS : reply_tokens
  end

  def always_reasons?(model)
    anthropic?(model) || model.to_s.delete_prefix("~").match?(%r{\Agoogle/gemini-(?:[3-9]|\d{2,})})
  end

  # Claude models on OpenRouter reject sampling settings (and require_parameters
  # would make OpenRouter refuse the call). Other models keep the temperature each
  # call was tuned with, so today's Gemini behavior is unchanged.
  def sampling(model, temperature)
    anthropic?(model) ? {} : { temperature: temperature }
  end

  def anthropic?(model)
    model.to_s.delete_prefix("~").start_with?("anthropic/")
  end

  def log_configuration(logger: Rails.logger, env: ENV)
    logger.info("[AiModels] text=#{text(env)} transcription=#{transcription(env)}")
    retired = RETIRED_ENV_KEYS.select { |key| env[key].to_s.strip.present? }
    return if retired.empty?

    logger.warn("[AiModels] ignoring retired model settings #{retired.join(', ')}; set AI_MODEL or AI_TRANSCRIPTION_MODEL instead")
  end

  def first_present(env, keys)
    keys.lazy.map { |key| env[key].to_s.strip }.find(&:present?)
  end
end
