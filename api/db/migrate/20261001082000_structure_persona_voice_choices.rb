# frozen_string_literal: true

require "digest"
require "json"

class StructurePersonaVoiceChoices < ActiveRecord::Migration[8.1]
  TONE_TRAITS = %w[
    warm direct respectful calm encouraging candid patient concise practical reassuring lighthearted formal clear unhurried
  ].freeze
  ENERGY_STYLES = [
    "Calm and focused.",
    "Calm, clear, and concise.",
    "Steady and reassuring.",
    "Warm and encouraging.",
    "Direct and energetic.",
    "Quiet and unhurried."
  ].freeze
  ACCOUNTABILITY_STYLES = [
    "Name choices and patterns clearly while protecting the participant's dignity.",
    "Ask reflective questions before naming a pattern.",
    "Be direct about tradeoffs while staying respectful.",
    "Use gentle accountability and one practical next step.",
    "Keep accountability firm, calm, and specific."
  ].freeze
  LANGUAGE_STYLES = [
    "Use plain language.",
    "Keep the next step concrete.",
    "Use short sentences and concrete questions.",
    "Prefer conversational language.",
    "Keep the tone professional and formal.",
    "Use light humor only when the situation is not sensitive.",
    "Be concise and avoid unnecessary jargon.",
    "Explain unfamiliar financial terms briefly."
  ].freeze

  class MigrationPersona < ActiveRecord::Base
    self.table_name = "coach_personas"
  end

  class MigrationVersion < ActiveRecord::Base
    self.table_name = "coach_persona_versions"
  end

  def up
    MigrationPersona.find_each do |persona|
      config, changed = normalize_config(persona.draft_config)
      next unless changed

      persona.update_columns(
        draft_config: config,
        draft_revision: persona.draft_revision + 1,
        preview_digest: nil,
        previewed_at: nil,
        previewed_draft_revision: nil,
        updated_at: Time.current
      )
    end

    MigrationVersion.find_each do |version|
      config, changed = normalize_config(version.config)
      next unless changed

      version.update_columns(config: config, config_digest: config_digest(config), updated_at: Time.current)
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "legacy free-form voice instructions cannot be reconstructed"
  end

  private

  def normalize_config(raw_config)
    config = raw_config.deep_stringify_keys.deep_dup
    voice = config["voice"]
    return [ config, false ] unless voice.is_a?(Hash)

    normalized = {
      "tone_traits" => normalized_tones(voice["tone_traits"]),
      "energy" => normalized_energy(voice["energy"]),
      "accountability_style" => normalized_accountability(voice["accountability_style"]),
      "language_style" => normalized_language(voice["language_style"])
    }
    return [ config, false ] if voice == normalized

    config["voice"] = normalized
    [ config, true ]
  end

  def normalized_tones(value)
    source = Array(value).join(" ").downcase
    selected = TONE_TRAITS.select { |trait| source.match?(/\b#{Regexp.escape(trait)}\b/) }
    selected << "warm" if source.match?(/\b(?:empathetic|friendly|welcoming)\b/)
    selected << "practical" if source.match?(/\bgrounded\b/)
    selected << "lighthearted" if source.match?(/\b(?:funny|humorous|playful)\b/)
    selected << "formal" if source.match?(/\bprofessional\b/)
    selected << "calm" if source.match?(/\bmeasured\b/)
    selected.uniq.presence || %w[warm direct respectful]
  end

  def normalized_energy(value)
    source = value.to_s
    return source if ENERGY_STYLES.include?(source)
    return "Direct and energetic." if source.match?(/\b(?:direct|energetic|high.energy)\b/i)
    return "Warm and encouraging." if source.match?(/\b(?:warm|encourag)\w*/i)
    return "Steady and reassuring." if source.match?(/\b(?:steady|reassur|confiden)\w*/i)
    return "Quiet and unhurried." if source.match?(/\b(?:quiet|unhurried|slow)\b/i)
    return "Calm, clear, and concise." if source.match?(/\b(?:clear|concise|exact)\b/i)

    "Calm and focused."
  end

  def normalized_accountability(value)
    source = value.to_s
    return source if ACCOUNTABILITY_STYLES.include?(source)
    return ACCOUNTABILITY_STYLES[1] if source.match?(/\b(?:reflect|question|ask)\w*/i)
    return ACCOUNTABILITY_STYLES[3] if source.match?(/\b(?:gentle|support)\w*/i)
    return ACCOUNTABILITY_STYLES[4] if source.match?(/\b(?:firm|specific)\b/i)
    return ACCOUNTABILITY_STYLES[2] if source.match?(/\b(?:direct|trade.?off)\w*/i)

    ACCOUNTABILITY_STYLES[0]
  end

  def normalized_language(value)
    values = Array(value).map(&:to_s)
    return values if values.present? && values.all? { |item| LANGUAGE_STYLES.include?(item) }

    source = values.join(" ")
    selected = []
    selected << LANGUAGE_STYLES[0] if source.match?(/\b(?:plain|simple)\b/i)
    selected << LANGUAGE_STYLES[1] if source.match?(/\b(?:concrete|next step|actionable)\b/i)
    selected << LANGUAGE_STYLES[2] if source.match?(/\b(?:short sentences?|concrete questions?)\b/i)
    selected << LANGUAGE_STYLES[3] if source.match?(/\bconversational\b/i)
    selected << LANGUAGE_STYLES[4] if source.match?(/\b(?:professional|formal)\b/i)
    selected << LANGUAGE_STYLES[5] if source.match?(/\b(?:humou?r|lighthearted|joke)\w*/i)
    selected << LANGUAGE_STYLES[6] if source.match?(/\b(?:concise|brief|jargon)\b/i)
    selected << LANGUAGE_STYLES[7] if source.match?(/\b(?:explain|define).{0,30}\b(?:term|jargon)\w*/i)
    selected.uniq.presence || LANGUAGE_STYLES.first(2)
  end

  def config_digest(config)
    Digest::SHA256.hexdigest(JSON.generate(canonicalize(config)).b)
  end

  def canonicalize(value)
    case value
    when Hash
      value.keys.sort.each_with_object({}) { |key, result| result[key] = canonicalize(value.fetch(key)) }
    when Array
      value.map { |child| canonicalize(child) }
    else
      value
    end
  end
end
