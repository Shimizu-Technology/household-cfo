require "net/http"

module Scorecard
  module Offline
    def self.call
      methods = [ [ Net::HTTP.singleton_class, :start ], [ Net::HTTP, :start ], [ Net::HTTP, :request ] ]
      originals = methods.map { |owner, name| [ owner, name, owner.instance_method(name) ] }
      methods.each { |owner, name| owner.define_method(name) { |*args, **options, &block| raise "Scorecard must never use the network" } }
      yield
    ensure
      originals&.each { |owner, name, original| owner.define_method(name, original) }
    end
  end
end
