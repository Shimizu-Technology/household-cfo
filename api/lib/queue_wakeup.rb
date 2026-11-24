require_relative "queue_wakeup/poller"

module QueueWakeup
  def self.enable!
    raise "Benchmark-only prototype; production activation is not approved" unless Rails.env.test?
    raise "Unsupported Solid Queue version" unless Gem.loaded_specs.fetch("solid_queue").version.to_s == "1.4.0"
    raise "A direct QUEUE_LISTEN_DATABASE_URL is required" if ENV["QUEUE_LISTEN_DATABASE_URL"].to_s.empty?
    SolidQueue::Worker.prepend(Poller) unless SolidQueue::Worker < Poller
    SolidQueue::Dispatcher.prepend(Poller) unless SolidQueue::Dispatcher < Poller
  end
end
