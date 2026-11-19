# frozen_string_literal: true

if ENV["STORAGE_BACKEND"] == "local" && !(Rails.env.development? || Rails.env.test?)
  raise "Local storage is only allowed in development and test"
end
