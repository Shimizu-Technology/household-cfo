# frozen_string_literal: true

require "tempfile"

module FinancialDocuments
  class PrivateSourceReader
    class TooLarge < StandardError; end
    MAX_BYTES = UploadLimits::STRUCTURED_SOURCE_MAX_BYTES

    def self.read(key)
      Tempfile.create([ "authorized-source", ".bin" ], binmode: true) do |file|
        # Reject an oversized replacement while it is streaming, before loading
        # its bytes in memory. Uploaded metadata is not a trusted object limit.
        file.define_singleton_method(:write) do |bytes|
          raise TooLarge, "Private source exceeds the supported size" if pos + bytes.bytesize > MAX_BYTES

          super(bytes)
        end
        S3Service.download_to_io!(key, file)
        raise TooLarge, "Private source exceeds the supported size" if file.size > MAX_BYTES

        file.rewind
        file.read
      end
    end
  end
end
