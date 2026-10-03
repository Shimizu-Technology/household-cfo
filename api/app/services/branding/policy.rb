# frozen_string_literal: true

module Branding
  class Policy
    def initialize(user, workspace:)
      @user = user
      @workspace = workspace
    end

    def view?
      workspace&.allows?(user, :view)
    end

    def edit?
      workspace&.allows?(user, :edit)
    end

    def preview?
      workspace && (workspace.allows?(user, :edit) || workspace.allows?(user, :review))
    end

    def publish?
      workspace&.allows?(user, :publish)
    end

    private

    attr_reader :user, :workspace
  end
end
