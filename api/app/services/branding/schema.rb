# frozen_string_literal: true

require "digest"
require "json"
require "uri"

module Branding
  module Schema
    HEX_COLOR = /\A#[0-9a-f]{6}\z/
    DISPLAY_FONTS = %w[cormorant_garamond lora merriweather playfair_display source_serif_4 system_serif].freeze
    BODY_FONTS = %w[inter montserrat nunito_sans source_sans_3 system_sans].freeze
    COLOR_KEYS = %w[
      background surface surface_muted text text_muted border primary primary_hover primary_soft
      accent on_primary focus
    ].freeze
    TOP_LEVEL_KEYS = %w[
      schema_version product_name short_name organization_name participant_role_term powered_by_name powered_by_placement tagline
      welcome_heading welcome_description logo_url favicon_url support colors typography footer
    ].freeze
    DEFAULT_CONFIG = {
      "schema_version" => 1,
      "product_name" => "Household CFO",
      "short_name" => "Household CFO",
      "organization_name" => "Household CFO Method",
      "participant_role_term" => "household CFO",
      "powered_by_name" => "VERA",
      "powered_by_placement" => "header",
      "tagline" => "Your household finance command center",
      "welcome_heading" => "Your household money, in one clear place",
      "welcome_description" => "Plan the month, understand what changed, and make confident decisions with your coach's guidance.",
      "logo_url" => nil,
      "favicon_url" => nil,
      "support" => {
        "label" => "Contact your coach",
        "email" => nil,
        "url" => nil
      },
      "colors" => {
        "background" => "#f7f2ea",
        "surface" => "#fffdf8",
        "surface_muted" => "#fbf7ef",
        "text" => "#1f2421",
        "text_muted" => "#706d66",
        "border" => "#e2d9cb",
        "primary" => "#7b4a58",
        "primary_hover" => "#633944",
        "primary_soft" => "#f1e2e3",
        "accent" => "#b97352",
        "on_primary" => "#ffffff",
        "focus" => "#7b4a58"
      },
      "typography" => {
        "display" => "cormorant_garamond",
        "body" => "montserrat"
      },
      "footer" => {
        "text" => "Household CFO provides educational guidance and is not a substitute for individualized legal, tax, investment, or accounting advice.",
        "privacy_url" => nil,
        "terms_url" => nil
      }
    }.freeze
    SAFE_DEFAULT_CONFIG = DEFAULT_CONFIG.merge(
      "product_name" => "VERA",
      "short_name" => "VERA",
      "organization_name" => "VERA",
      "participant_role_term" => "participant",
      "powered_by_name" => nil,
      "powered_by_placement" => "hidden",
      "tagline" => "A secure coaching experience",
      "welcome_heading" => "This program link is not available",
      "welcome_description" => "Check the address from your coach and try again.",
      "support" => { "label" => nil, "email" => nil, "url" => nil },
      "colors" => {
        "background" => "#f7f2ea",
        "surface" => "#fffdf8",
        "surface_muted" => "#fbf7ef",
        "text" => "#1f2421",
        "text_muted" => "#706d66",
        "border" => "#e2d9cb",
        "primary" => "#536a63",
        "primary_hover" => "#3f524c",
        "primary_soft" => "#e5ece9",
        "accent" => "#9a7457",
        "on_primary" => "#ffffff",
        "focus" => "#536a63"
      },
      "typography" => { "display" => "system_serif", "body" => "system_sans" },
      "footer" => { "text" => nil, "privacy_url" => nil, "terms_url" => nil }
    ).freeze

    module_function

    def normalize(value)
      input = value.respond_to?(:to_h) ? value.to_h.deep_stringify_keys : {}
      colors = input.fetch("colors", {}).to_h.deep_stringify_keys
      typography = input.fetch("typography", {}).to_h.deep_stringify_keys

      {
        "schema_version" => Integer(input.fetch("schema_version", 1), exception: false),
        "product_name" => normalize_text(input["product_name"]),
        "short_name" => normalize_text(input["short_name"]),
        "organization_name" => normalize_text(input["organization_name"]),
        "participant_role_term" => normalize_text(input["participant_role_term"]),
        "powered_by_name" => normalize_optional_text(input["powered_by_name"]),
        "powered_by_placement" => input["powered_by_placement"].to_s,
        "tagline" => normalize_optional_text(input["tagline"]),
        "welcome_heading" => normalize_optional_text(input["welcome_heading"]),
        "welcome_description" => normalize_optional_text(input["welcome_description"]),
        "logo_url" => normalize_optional_text(input["logo_url"]),
        "favicon_url" => normalize_optional_text(input["favicon_url"]),
        "support" => normalize_support(input["support"]),
        "colors" => COLOR_KEYS.index_with { |key| colors[key].to_s.downcase },
        "typography" => {
          "display" => typography["display"].to_s,
          "body" => typography["body"].to_s
        },
        "footer" => normalize_footer(input["footer"])
      }
    end

    def errors(value)
      return [ "must be an object" ] unless value.respond_to?(:to_h)

      input = value.to_h.deep_stringify_keys
      result = []
      result << "must contain only supported brand fields" if (input.keys - TOP_LEVEL_KEYS).any?
      result << "schema_version must be 1" unless input["schema_version"] == 1

      validate_text(result, input, "product_name", maximum: 80, required: true)
      validate_text(result, input, "short_name", maximum: 32, required: true)
      validate_text(result, input, "organization_name", maximum: 100, required: true)
      validate_text(result, input, "participant_role_term", maximum: 48, required: true)
      validate_text(result, input, "powered_by_name", maximum: 80)
      result << "powered_by_placement is unsupported" unless %w[hidden header footer].include?(input["powered_by_placement"])
      validate_text(result, input, "tagline", maximum: 180)
      validate_text(result, input, "welcome_heading", maximum: 120)
      validate_text(result, input, "welcome_description", maximum: 320)
      validate_asset_url(result, input, "logo_url")
      validate_asset_url(result, input, "favicon_url")
      validate_support(result, input["support"])
      validate_colors(result, input["colors"])
      validate_typography(result, input["typography"])
      validate_footer(result, input["footer"])
      result
    end

    def digest(value)
      Digest::SHA256.hexdigest(JSON.generate(normalize(value)))
    end

    def preview_digest(value, draft_revision:)
      Digest::SHA256.hexdigest(JSON.generate({ "config" => normalize(value), "draft_revision" => draft_revision.to_i }))
    end

    # Authoring checks cover extra application surfaces without retroactively
    # invalidating already sealed brand snapshots during runtime resolution.
    def authoring_errors(value)
      result = errors(value)
      return result unless result.empty?

      colors = value.to_h.deep_stringify_keys.fetch("colors")
      %w[text primary focus].each do |foreground|
        %w[surface_muted primary_soft].each do |background|
          minimum = foreground == "focus" ? 3.0 : 4.5
          if contrast_ratio(colors[foreground], colors[background]) < minimum
            result << "colors.#{foreground} must have at least #{minimum}:1 contrast on colors.#{background}"
          end
        end
      end
      if contrast_ratio(colors["text_muted"], colors["surface_muted"]) < 4.5
        result << "colors.text_muted must have at least 4.5:1 contrast on colors.surface_muted"
      end
      result
    end

    def contrast_ratio(foreground, background)
      lighter, darker = [ relative_luminance(foreground), relative_luminance(background) ].sort.reverse
      (lighter + 0.05) / (darker + 0.05)
    end

    def normalize_text(value)
      value.to_s.squish
    end
    private_class_method :normalize_text

    def normalize_optional_text(value)
      normalize_text(value).presence
    end
    private_class_method :normalize_optional_text

    def normalize_support(value)
      support = value.respond_to?(:to_h) ? value.to_h.deep_stringify_keys : {}
      {
        "label" => normalize_optional_text(support["label"]),
        "email" => normalize_optional_text(support["email"])&.downcase,
        "url" => normalize_optional_text(support["url"])
      }
    end
    private_class_method :normalize_support

    def normalize_footer(value)
      footer = value.respond_to?(:to_h) ? value.to_h.deep_stringify_keys : {}
      {
        "text" => normalize_optional_text(footer["text"]),
        "privacy_url" => normalize_optional_text(footer["privacy_url"]),
        "terms_url" => normalize_optional_text(footer["terms_url"])
      }
    end
    private_class_method :normalize_footer

    def validate_text(result, input, key, maximum:, required: false)
      value = input[key]
      if required && !value.is_a?(String)
        result << "#{key} must be text"
        return
      end
      return if value.nil? && !required
      unless value.is_a?(String)
        result << "#{key} must be text or null"
        return
      end

      normalized = value.squish
      result << "#{key} cannot be blank" if required && normalized.blank?
      result << "#{key} is too long" if normalized.length > maximum
      result << "#{key} cannot contain control characters" if normalized.match?(/[[:cntrl:]]/)
    end
    private_class_method :validate_text

    def validate_asset_url(result, input, key)
      value = input[key]
      return if value.nil?
      unless value.is_a?(String)
        result << "#{key} must be an HTTPS URL or null"
        return
      end
      if value.length > 2_048
        result << "#{key} is too long"
        return
      end

      uri = URI.parse(value)
      valid = uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil? && uri.fragment.nil?
      result << "#{key} must be an HTTPS URL without credentials or a fragment" unless valid
    rescue URI::InvalidURIError
      result << "#{key} must be a valid HTTPS URL"
    end
    private_class_method :validate_asset_url

    def validate_support(result, value)
      unless value.is_a?(Hash)
        result << "support must be an object"
        return
      end

      support = value.deep_stringify_keys
      result << "support contains an unsupported field" if (support.keys - %w[label email url]).any?
      validate_text(result, support, "label", maximum: 80)
      email = support["email"]
      if email.present? && (!email.is_a?(String) || email.length > 254 || !URI::MailTo::EMAIL_REGEXP.match?(email))
        result << "support.email must be a valid email address or null"
      end
      validate_optional_https_url(result, support, "url", prefix: "support")
    end
    private_class_method :validate_support

    def validate_footer(result, value)
      unless value.is_a?(Hash)
        result << "footer must be an object"
        return
      end

      footer = value.deep_stringify_keys
      result << "footer contains an unsupported field" if (footer.keys - %w[text privacy_url terms_url]).any?
      validate_text(result, footer, "text", maximum: 500)
      validate_optional_https_url(result, footer, "privacy_url", prefix: "footer")
      validate_optional_https_url(result, footer, "terms_url", prefix: "footer")
    end
    private_class_method :validate_footer

    def validate_optional_https_url(result, input, key, prefix:)
      value = input[key]
      return if value.nil?
      unless value.is_a?(String) && value.length <= 2_048
        result << "#{prefix}.#{key} must be an HTTPS URL or null"
        return
      end

      uri = URI.parse(value)
      valid = uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil? && uri.fragment.nil?
      result << "#{prefix}.#{key} must be an HTTPS URL without credentials or a fragment" unless valid
    rescue URI::InvalidURIError
      result << "#{prefix}.#{key} must be a valid HTTPS URL"
    end
    private_class_method :validate_optional_https_url

    def validate_colors(result, value)
      unless value.is_a?(Hash)
        result << "colors must be an object"
        return
      end

      colors = value.deep_stringify_keys
      result << "colors contains an unsupported color" if (colors.keys - COLOR_KEYS).any?
      COLOR_KEYS.each do |key|
        result << "colors.#{key} must be a six-digit hex color" unless colors[key].is_a?(String) && colors[key].downcase.match?(HEX_COLOR)
      end
      return if result.any? { |message| message.start_with?("colors.") }

      result << "colors.text must have at least 4.5:1 contrast on colors.background" if contrast_ratio(colors["text"], colors["background"]) < 4.5
      result << "colors.text must have at least 4.5:1 contrast on colors.surface" if contrast_ratio(colors["text"], colors["surface"]) < 4.5
      result << "colors.on_primary must have at least 4.5:1 contrast on colors.primary" if contrast_ratio(colors["on_primary"], colors["primary"]) < 4.5
      result << "colors.on_primary must have at least 4.5:1 contrast on colors.primary_hover" if contrast_ratio(colors["on_primary"], colors["primary_hover"]) < 4.5
      result << "colors.primary must have at least 4.5:1 contrast on colors.background" if contrast_ratio(colors["primary"], colors["background"]) < 4.5
      result << "colors.primary must have at least 4.5:1 contrast on colors.surface" if contrast_ratio(colors["primary"], colors["surface"]) < 4.5
      result << "colors.text_muted must have at least 4.5:1 contrast on colors.background" if contrast_ratio(colors["text_muted"], colors["background"]) < 4.5
      result << "colors.text_muted must have at least 4.5:1 contrast on colors.surface" if contrast_ratio(colors["text_muted"], colors["surface"]) < 4.5
      result << "colors.focus must have at least 3:1 contrast on colors.background" if contrast_ratio(colors["focus"], colors["background"]) < 3.0
      result << "colors.focus must have at least 3:1 contrast on colors.surface" if contrast_ratio(colors["focus"], colors["surface"]) < 3.0
    end
    private_class_method :validate_colors

    def validate_typography(result, value)
      unless value.is_a?(Hash)
        result << "typography must be an object"
        return
      end

      typography = value.deep_stringify_keys
      result << "typography must contain only display and body" if (typography.keys - %w[display body]).any?
      result << "typography.display is unsupported" unless DISPLAY_FONTS.include?(typography["display"])
      result << "typography.body is unsupported" unless BODY_FONTS.include?(typography["body"])
    end
    private_class_method :validate_typography

    def relative_luminance(color)
      rgb = color.delete_prefix("#").scan(/../).map { |component| component.to_i(16) / 255.0 }
      rgb.map! { |component| component <= 0.04045 ? component / 12.92 : ((component + 0.055) / 1.055)**2.4 }
      (0.2126 * rgb[0]) + (0.7152 * rgb[1]) + (0.0722 * rgb[2])
    end
    private_class_method :relative_luminance
  end
end
