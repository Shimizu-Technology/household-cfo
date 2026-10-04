class ChallengePrivacyRead < SourceReviewImmutableRecord
  include ChallengePrivacyScoped
  belongs_to :actor_user, class_name: "User"
end
