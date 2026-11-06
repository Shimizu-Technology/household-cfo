# frozen_string_literal: true

require "timeout"

module Mia
  # One budget shared by the reader, resolver, generation, rewrite and guard.
  # Direct demo/narrator calls get the same bound; nested calls never reset it.
  module ReplyDeadline
    class Exceeded < StandardError; end
    class Current < ActiveSupport::CurrentAttributes
      attribute :expires_at
    end
    SECONDS = 60
    module_function

    def within
      return yield if Current.expires_at
      Current.set(expires_at: monotonic + SECONDS) { yield }
    end

    def remaining
      return unless Current.expires_at
      seconds = Current.expires_at - monotonic
      raise Exceeded if seconds <= 0
      seconds
    end

    def check! = remaining
    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
