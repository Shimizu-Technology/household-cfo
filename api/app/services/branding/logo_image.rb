# frozen_string_literal: true

require "zlib"

module Branding
  # Keep the upload contract deliberately small: static PNG, validated and
  # rewritten without text, EXIF, profiles, animation or trailing payloads.
  class LogoImage
    class Invalid < StandardError; end

    MAX_BYTES = 2.megabytes
    MAX_DIMENSION = 2048
    SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze
    DEPTHS = { 0 => [ 1, 2, 4, 8, 16 ], 2 => [ 8, 16 ], 3 => [ 1, 2, 4, 8 ], 4 => [ 8, 16 ], 6 => [ 8, 16 ] }.freeze
    CHANNELS = { 0 => 1, 2 => 3, 3 => 1, 4 => 2, 6 => 4 }.freeze

    def self.read!(file)
      unless file.is_a?(ActionDispatch::Http::UploadedFile) && file.content_type == "image/png"
        raise Invalid, "Choose a PNG logo. Other file types are not supported."
      end
      raise Invalid, "Choose a logo smaller than 2 MB." if file.size > MAX_BYTES

      file.rewind
      bytes = file.read(MAX_BYTES + 1).to_s.b
      raise Invalid, "Choose a logo smaller than 2 MB." if bytes.bytesize > MAX_BYTES

      new(bytes).sanitize
    ensure
      file&.rewind if file.respond_to?(:rewind)
    end

    def initialize(bytes)
      @bytes = bytes
    end

    def sanitize
      invalid! unless @bytes.start_with?(SIGNATURE)
      offset = SIGNATURE.bytesize
      chunks = []
      compressed = +"".b
      data_ended = false
      ended = false
      while offset < @bytes.bytesize
        invalid! if ended || offset + 12 > @bytes.bytesize
        length = @bytes.byteslice(offset, 4).unpack1("N")
        invalid! if length > MAX_BYTES || offset + length + 12 > @bytes.bytesize
        type = @bytes.byteslice(offset + 4, 4)
        data = @bytes.byteslice(offset + 8, length)
        crc = @bytes.byteslice(offset + 8 + length, 4).unpack1("N")
        invalid! unless type.match?(/\A[A-Za-z]{4}\z/) && Zlib.crc32(type + data) == crc
        invalid! if chunks.empty? && type != "IHDR"
        data_ended = true if compressed.present? && type != "IDAT"
        case type
        when "IHDR"
          invalid! unless chunks.empty? && length == 13
          @width, @height, @depth, @color, compression, filter, interlace = data.unpack("NNC5")
          unless @width.between?(1, MAX_DIMENSION) && @height.between?(1, MAX_DIMENSION)
            raise Invalid, "Choose a logo no larger than 2048 × 2048 pixels."
          end
          invalid! unless DEPTHS.fetch(@color, []).include?(@depth) && compression.zero? && filter.zero?
          raise Invalid, "Save your logo as a non-interlaced PNG and try again." unless interlace.zero?
          chunks << [ type, data ]
        when "PLTE"
          invalid! if compressed.present? || chunks.any? { |entry| entry.first == "PLTE" } || [ 0, 4 ].include?(@color)
          invalid! unless length.positive? && (length % 3).zero? && length <= 768
          invalid! if @color == 3 && length / 3 > 2**@depth
          chunks << [ type, data ]
        when "tRNS"
          invalid! if compressed.present? || chunks.any? { |entry| entry.first == "tRNS" }
          palette = chunks.find { |entry| entry.first == "PLTE" }&.last
          valid = case @color
          when 0 then length == 2
          when 2 then length == 6
          when 3 then palette && length.positive? && length <= palette.bytesize / 3
          else false
          end
          invalid! unless valid
          chunks << [ type, data ]
        when "IDAT"
          invalid! if data_ended || (@color == 3 && chunks.none? { |entry| entry.first == "PLTE" })
          compressed << data
        when "IEND"
          invalid! unless length.zero? && compressed.present?
          ended = true
        else
          # Unknown critical chunks cannot be safely interpreted. All ancillary
          # chunks (including APNG and metadata) are discarded from the result.
          invalid! if type.getbyte(0).between?(65, 90)
        end
        offset += length + 12
      end
      invalid! unless ended
      validate_pixels!(compressed)
      SIGNATURE + (chunks + [ [ "IDAT", compressed ], [ "IEND", "".b ] ]).map { |type, data| encode(type, data) }.join
    rescue Zlib::Error, ArgumentError
      invalid!
    end

    private

    def validate_pixels!(compressed)
      stride = (@width * CHANNELS.fetch(@color) * @depth + 7) / 8 + 1
      expected = stride * @height
      size = 0
      inflater = Zlib::Inflate.new
      compressed.bytes.each_slice(1024) do |slice|
        inflater.inflate(slice.pack("C*")) do |part|
          invalid! if size + part.bytesize > expected
          first_filter = (stride - size % stride) % stride
          first_filter.step(part.bytesize - 1, stride) { |index| invalid! if part.getbyte(index) > 4 }
          size += part.bytesize
        end
      end
      invalid! unless inflater.finished? && inflater.total_in == compressed.bytesize && size == expected
    ensure
      inflater&.close
    end

    def encode(type, data)
      [ data.bytesize ].pack("N") + type + data + [ Zlib.crc32(type + data) ].pack("N")
    end

    def invalid!
      raise Invalid, "This file is not a readable PNG logo. Save it as a PNG and try again."
    end
  end
end
