# frozen_string_literal: true

class CoachProfile < ApplicationRecord
  belongs_to :coach_workspace, inverse_of: :coach_profile
  belongs_to :last_edited_by_user, class_name: "User", optional: true

  normalizes :display_name, with: ->(value) { value.to_s.squish }
  normalizes :title, with: ->(value) { value.to_s.squish }

  validates :coach_workspace_id, uniqueness: true
  validates :display_name, presence: true, length: { maximum: 120 }
  validates :title, presence: true, length: { maximum: 160 }
  validates :bio, length: { maximum: 2_000 }, allow_blank: true
  validate :editor_can_edit_workspace

  private

  def editor_can_edit_workspace
    return if last_edited_by_user.nil? || coach_workspace&.allows?(last_edited_by_user, :edit)

    errors.add(:last_edited_by_user, "cannot edit this coach workspace")
  end
end
