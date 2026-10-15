# frozen_string_literal: true

module FileSafety
  # Bounds an Office Open XML (DOCX/XLSX) package before RubyZip, Nokogiri or
  # Roo materializes it. #check! reads only the end record and the central
  # directory, never inflating an entry, so a zip bomb, an entry flood or an
  # encrypted/path-traversal entry is rejected without decompressing anything.
  # RubyZip then enforces the declared sizes while inflating
  # (Zip.validate_entry_sizes), which keeps the totals checked here honest.
  #
  # Errors carry a generic code; each caller maps it to its own wording.
  class OoxmlGuard
    class Error < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super(code)
      end
    end

    EOCD_MIN_BYTES = 22
    MAX_COMMENT_BYTES = 65_535
    DEFAULT_MAX_CENTRAL_DIRECTORY_BYTES = 2 * 1024 * 1024
    ZIP64_SENTINEL_32 = 0xffffffff
    ZIP64_SENTINEL_16 = 0xffff

    def self.unsafe_entry_name?(name)
      name = name.to_s
      name.start_with?("/", "\\") || name.split(/[\\\/]/).include?("..") || name.include?("\0")
    end

    # Reads at most max_bytes + 1 bytes of one entry.
    def self.read_entry!(zip, name, max_bytes:)
      entry = zip.find_entry(name)
      raise Error, "missing_entry" unless entry
      raise Error, "entry_too_large" if entry.size > max_bytes

      entry.get_input_stream.read(max_bytes + 1).to_s.tap { |value| raise Error, "entry_too_large" if value.bytesize > max_bytes }
    end

    # Package XML never needs a DTD; refusing one rules out entity expansion
    # and external entity reads regardless of parser settings.
    def self.check_xml!(xml)
      scan = xml.to_s
      if scan.include?("\0")
        encoding = scan.start_with?("\xFE\xFF".b) ? Encoding::UTF_16BE : Encoding::UTF_16LE
        scan = scan.dup.force_encoding(encoding).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      end
      raise Error, "unsafe" if scan.match?(/<!DOCTYPE|<!ENTITY/i)
    end

    # ratio_floor_bytes lets small, highly repetitive XML parts (styles,
    # empty-cell runs) through the ratio check; the total cap still applies.
    def initialize(max_file_bytes:, max_entries:, max_uncompressed:, max_ratio:,
      max_central_directory_bytes: DEFAULT_MAX_CENTRAL_DIRECTORY_BYTES, ratio_floor_bytes: 0)
      @max_file_bytes = max_file_bytes
      @max_entries = max_entries
      @max_uncompressed = max_uncompressed
      @max_ratio = max_ratio
      @max_central_directory_bytes = max_central_directory_bytes
      @ratio_floor_bytes = ratio_floor_bytes
    end

    def check!(path)
      file_size = File.size(path)
      raise Error, "file_too_large" if file_size > max_file_bytes
      raise Error, "invalid" if file_size < EOCD_MIN_BYTES

      File.open(path, "rb") do |file|
        tail_size = [ file_size, EOCD_MIN_BYTES + MAX_COMMENT_BYTES ].min
        file.seek(-tail_size, IO::SEEK_END)
        tail = file.read(tail_size)
        eocd_offset = tail.rindex("PK\x05\x06".b)
        raise Error, "invalid" unless eocd_offset

        eocd = tail.byteslice(eocd_offset, EOCD_MIN_BYTES)
        raise Error, "invalid" unless eocd&.bytesize == EOCD_MIN_BYTES
        signature, disk_number, directory_disk, disk_entries, total_entries, directory_size, directory_offset, comment_size = eocd.unpack("VvvvvVVv")
        raise Error, "invalid" unless signature == 0x06054b50 && eocd_offset + EOCD_MIN_BYTES + comment_size == tail.bytesize
        raise Error, "unsafe" unless disk_number.zero? && directory_disk.zero? && disk_entries == total_entries
        raise Error, "unsafe" if [ total_entries, disk_entries ].include?(ZIP64_SENTINEL_16) || [ directory_size, directory_offset ].include?(ZIP64_SENTINEL_32)
        raise Error, "too_many_entries" if total_entries > max_entries
        raise Error, "unsafe" if directory_size > max_central_directory_bytes || directory_offset + directory_size > file_size

        file.seek(directory_offset, IO::SEEK_SET)
        directory = file.read(directory_size)
        raise Error, "invalid" unless directory&.bytesize == directory_size
        check_central_directory!(directory, total_entries)
      end
      true
    rescue Errno::ENOENT, Errno::EINVAL
      raise Error, "invalid"
    end

    # Repeats the per-entry checks on RubyZip's view of an opened archive.
    def check_entries!(entries)
      total = 0
      entries.each do |entry|
        raise Error, "unsafe" if self.class.unsafe_entry_name?(entry.name) || (entry.respond_to?(:encrypted?) && entry.encrypted?)

        total += entry.size
        raise Error, "too_large_uncompressed" if total > max_uncompressed
        raise Error, "unsafe" if excessive_ratio?(entry.size, entry.compressed_size.to_i)
      end
      true
    end

    private

    attr_reader :max_file_bytes, :max_entries, :max_uncompressed, :max_ratio, :max_central_directory_bytes, :ratio_floor_bytes

    def check_central_directory!(directory, expected_entries)
      offset = 0
      total_uncompressed = 0
      expected_entries.times do
        header = directory.byteslice(offset, 46)
        raise Error, "invalid" unless header&.bytesize == 46 && header.unpack1("V") == 0x02014b50

        flags = header.byteslice(8, 2).unpack1("v")
        compressed_size = header.byteslice(20, 4).unpack1("V")
        uncompressed_size = header.byteslice(24, 4).unpack1("V")
        name_size = header.byteslice(28, 2).unpack1("v")
        extra_size = header.byteslice(30, 2).unpack1("v")
        comment_size = header.byteslice(32, 2).unpack1("v")
        entry_size = 46 + name_size + extra_size + comment_size
        raise Error, "invalid" if offset + entry_size > directory.bytesize
        name = directory.byteslice(offset + 46, name_size).to_s.force_encoding(Encoding::UTF_8).scrub
        extra = directory.byteslice(offset + 46 + name_size, extra_size).to_s
        uncompressed_size, compressed_size = zip64_entry_sizes(
          extra, uncompressed_size: uncompressed_size, compressed_size: compressed_size
        )
        raise Error, "unsafe" if (flags & 0x1).positive?
        raise Error, "unsafe" if self.class.unsafe_entry_name?(name)

        total_uncompressed += uncompressed_size
        raise Error, "too_large_uncompressed" if total_uncompressed > max_uncompressed
        raise Error, "unsafe" if excessive_ratio?(uncompressed_size, compressed_size)

        offset += entry_size
      end
      raise Error, "invalid" unless offset == directory.bytesize
    end

    def excessive_ratio?(uncompressed_size, compressed_size)
      return false unless uncompressed_size.positive?
      return false if uncompressed_size < ratio_floor_bytes

      compressed_size.zero? || uncompressed_size.to_f / compressed_size > max_ratio
    end

    def zip64_entry_sizes(extra, uncompressed_size:, compressed_size:)
      return [ uncompressed_size, compressed_size ] unless [ uncompressed_size, compressed_size ].include?(ZIP64_SENTINEL_32)

      cursor = 0
      payload = nil
      while cursor + 4 <= extra.bytesize
        field_id, field_size = extra.byteslice(cursor, 4).unpack("vv")
        cursor += 4
        raise Error, "invalid" if cursor + field_size > extra.bytesize
        payload = extra.byteslice(cursor, field_size) if field_id == 0x0001
        cursor += field_size
      end
      raise Error, "unsafe" unless payload

      value_cursor = 0
      if uncompressed_size == ZIP64_SENTINEL_32
        raise Error, "unsafe" if value_cursor + 8 > payload.bytesize
        uncompressed_size = payload.byteslice(value_cursor, 8).unpack1("Q<")
        value_cursor += 8
      end
      if compressed_size == ZIP64_SENTINEL_32
        raise Error, "unsafe" if value_cursor + 8 > payload.bytesize
        compressed_size = payload.byteslice(value_cursor, 8).unpack1("Q<")
      end
      [ uncompressed_size, compressed_size ]
    end
  end
end
