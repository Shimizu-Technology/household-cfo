# frozen_string_literal: true

module HouseholdFinance
  class MiaProviderAdmission
    PROVIDER = "openrouter_mia"
    DEFAULT_LIMIT = 4
    MAX_LIMIT = 16
    LEASE_TTL = 30.seconds

    def self.with_slot(**options, &block)
      new(**options).call(&block)
    end

    def initialize(provider: PROVIDER, limit: configured_limit, lease_ttl: LEASE_TTL)
      @provider = provider
      @limit = limit.to_i.clamp(1, MAX_LIMIT)
      @lease_ttl = lease_ttl
    end

    def call
      lease = acquire
      unless lease
        instrument(admitted: false)
        Rails.logger.info("[HouseholdFinance::MiaProviderAdmission] provider capacity full; using deterministic fallback")
        return nil
      end

      instrument(admitted: true)
      yield
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("[HouseholdFinance::MiaProviderAdmission] admission fallback: #{e.class}: #{e.message}")
      nil
    ensure
      release(lease) if lease
    end

    private

    attr_reader :provider, :limit, :lease_ttl

    def acquire
      now = Time.current
      ProviderCallLease.where(provider: provider).where(expires_at: ..now).delete_all
      occupied_slots = ProviderCallLease.where(provider: provider).pluck(:slot)

      ((1..limit).to_a - occupied_slots).each do |slot|
        token = SecureRandom.uuid
        return ProviderCallLease.create!(
          provider: provider,
          slot: slot,
          owner_token: token,
          expires_at: now + lease_ttl
        )
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
        next
      end

      nil
    end

    def release(lease)
      ProviderCallLease.where(id: lease.id, owner_token: lease.owner_token).delete_all
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("[HouseholdFinance::MiaProviderAdmission] lease release failed: #{e.class}: #{e.message}")
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
