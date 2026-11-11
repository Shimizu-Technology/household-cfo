# frozen_string_literal: true

# Evidence that a program owner cancelled a participant's pending invitation. Written once, never edited.
class ParticipantInvitationCancellation < ApplicationRecord
  belongs_to :coach_workspace
  belongs_to :actor_user, class_name: "User"
  belongs_to :subject_user, class_name: "User"
  validates :subject_email, presence: true
  before_update { throw :abort }
  before_destroy { throw :abort }
end
