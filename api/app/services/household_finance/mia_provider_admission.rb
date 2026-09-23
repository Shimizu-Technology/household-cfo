# frozen_string_literal: true

require "digest"

module HouseholdFinance
  class MiaProviderAdmission
    PROVIDER = "openrouter_mia"
    DEFAULT_LIMIT = 4
    MAX_LIMIT = 16
    DEFAULT_WAIT_MS = 1_000
    MAX_WAIT_MS = 5_000
    POLL_INTERVAL_SECONDS = 0.05

    def self.with_slot(**options, &block)
      new(**options).call(&block)
    end

    def initialize(provider: PROVIDER, limit: configured_limit, wait_ms: configured_wait_ms)
      @provider = provider
      @limit = limit.to_i.clamp(1, MAX_LIMIT)
      @wait_ms = wait_ms.to_i.clamp(0, MAX_WAIT_MS)
    end

    def call
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        slot = acquire_with_wait(connection)
        waited_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
        unless slot
          instrument(admitted: false, waited_ms: waited_ms)
          Rails.logger.info("[HouseholdFinance::MiaProviderAdmission] provider capacity full after #{waited_ms}ms; using deterministic fallback")
          return nil
        end

        instrument(admitted: true, waited_ms: waited_ms)
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

    attr_reader :provider, :limit, :wait_ms

    def acquire_with_wait(connection)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + (wait_ms / 1000.0)
      loop do
        slot = acquire(connection)
        return slot if slot
        return if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep(POLL_INTERVAL_SECONDS)
      end
    end

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

    def instrument(admitted:, waited_ms:)
      ActiveSupport::Notifications.instrument(
        "mia.provider_admission",
        provider: provider,
        admitted: admitted,
        limit: limit,
        waited_ms: waited_ms
      )
    end

    def self.configured_limit
      ENV.fetch("MIA_PROVIDER_MAX_CONCURRENCY", DEFAULT_LIMIT).to_i
    end

    def configured_limit
      self.class.configured_limit
    end

    def self.configured_wait_ms
      ENV.fetch("MIA_PROVIDER_ADMISSION_WAIT_MS", DEFAULT_WAIT_MS).to_i
    end

    def configured_wait_ms
      self.class.configured_wait_ms
    end
  end
end
