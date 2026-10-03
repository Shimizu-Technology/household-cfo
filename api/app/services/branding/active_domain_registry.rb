# frozen_string_literal: true

module Branding
  class ActiveDomainRegistry
    CACHE_KEY = "branding/active-domain-workspaces/v1"
    CACHE_TTL = 60.seconds

    class << self
      def workspace_id_for(hostname)
        return nil if hostname.blank?

        snapshot[hostname.to_s]
      end

      def active?(hostname)
        workspace_id_for(hostname).present?
      end

      def invalidate!
        Rails.cache.delete(CACHE_KEY)
      end

      private

      def snapshot
        Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) do
          CoachWorkspaceDomain.active.pluck(:hostname, :coach_workspace_id).to_h
        end
      end
    end
  end
end
