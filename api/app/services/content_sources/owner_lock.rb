# frozen_string_literal: true

require "digest"

module ContentSources
  class OwnerLock
    class << self
      def call(owner_key, &block)
        ApplicationRecord.transaction(requires_new: true) do
          first_key, second_key = Digest::SHA256.digest("content-source-owner:#{owner_key}").unpack("l>2")
          integer = ActiveRecord::Type::Integer.new
          binds = [ first_key, second_key ].each_with_index.map do |value, index|
            ActiveRecord::Relation::QueryAttribute.new("key#{index}", value, integer)
          end
          ApplicationRecord.connection.exec_query(
            "SELECT pg_advisory_xact_lock($1, $2)", "Content source owner lock", binds
          )
          block.call
        end
      end
    end
  end
end
