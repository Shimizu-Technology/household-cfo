# frozen_string_literal: true

require "digest"

module HouseholdFinance
  class MiaProviderAdmission
    PROVIDER = "openrouter_mia"
    DEFAULT_LIMIT = 4
    MAX_LIMIT = 16

    def self.with_slot(**options, &block)
      new(**options).call(&block)
    end

    def initialize(provider: PROVIDER, limit: configured_limit)
      @provider = provider
      @limit = limit.to_i.clamp(1, MAX_LIMIT)
    end

    def call
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        slot = acquire(connection)
        unless slot
          instrument(admitted: false)
          Rails.logger.info("[HouseholdFinance::MiaProviderAdmission] provider capacity full; using deterministic fallback")
          return nil
        end

        instrument(admitted: true)
        begin
          yield
        ensure
          release(connection, slot)
        end
      end
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("[HouseholdFinance::MiaProviderAdmission] admission fallback: #{e.class}: #{e.message}")
      nil
    end

    private

    attr_reader :provider, :limit

    def acquire(connection)
      (1..limit).find do |slot|
        ActiveModel::Type::Boolean.new.cast(
          connection.select_value("SELECT pg_try_advisory_lock(#{provider_key}, #{slot})")
        )
      end
    end

    def release(connection, slot)
      connection.select_value("SELECT pg_advisory_unlock(#{provider_key}, #{slot})")
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("[HouseholdFinance::MiaProviderAdmission] provider slot release failed: #{e.class}: #{e.message}")
    end

    def provider_key
      @provider_key ||= Digest::SHA256.digest(provider).unpack1("l>")
    end

    def instrument(admitted:)
      ActiveSupport::Notifications.instrument(
        "mia.provider_admission",
        provider: provider,
        admitted: admitted,
        limit: limit
      )
    end

    def self.configured_limit
      ENV.fetch("MIA_PROVIDER_MAX_CONCURRENCY", DEFAULT_LIMIT).to_i
    end

    def configured_limit
      self.class.configured_limit
    end
  end
end
