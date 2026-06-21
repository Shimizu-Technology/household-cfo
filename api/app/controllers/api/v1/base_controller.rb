module Api
  module V1
    class BaseController < ApplicationController
      include ClerkAuthenticatable
    end
  end
end
