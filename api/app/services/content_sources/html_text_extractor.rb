# frozen_string_literal: true

require "nokogiri"

module ContentSources
  class HtmlTextExtractor
    MAX_TEXT_CHARS = ContentSources::Parser::MAX_CHARS

    def call(bytes)
      bytes = bytes.to_s.dup.force_encoding(Encoding::UTF_8)
      raise Error, "invalid_text" unless bytes.valid_encoding?
      raise Error, "html_unsafe" if bytes.match?(/<!DOCTYPE[^>]+\bSYSTEM\b|<!ENTITY/i)

      document = Nokogiri::HTML5(bytes, max_errors: 0)
      document.css("script,style,template,noscript,svg,canvas,iframe,object,embed,form").remove
      text = document.xpath("//body//text()[normalize-space()]").map { |node| node.text.gsub(/\s+/, " ").strip }
        .reject(&:blank?).join("\n")
      raise Error, "html_no_readable_text" if text.scan(/[[:alnum:]]/).length < 20
      raise Error, "too_much_text" if text.length > MAX_TEXT_CHARS

      "#{text}\n"
    rescue Nokogiri::XML::SyntaxError
      raise Error, "html_invalid"
    end
  end
end
