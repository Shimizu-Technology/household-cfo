# frozen_string_literal: true

class CoachContentSourceUrlIntakeAttempt < ApplicationRecord
  belongs_to :coach_content_source_url_intake

  before_update { throw(:abort) }
end
