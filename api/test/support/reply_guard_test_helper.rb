# frozen_string_literal: true

# Generator/shape tests use a separate, explicitly passing classifier. The
# fail-closed wire and delivery integration are exercised in mia_reply_guard_test.
module ReplyGuardTestHelper
  def self.included(base)
    base.setup do
      @original_guard_admission = HouseholdFinance::MiaProviderAdmission.singleton_class.instance_method(:with_slot)
      HouseholdFinance::MiaProviderAdmission.singleton_class.define_method(:with_slot) { |**_, &block| block.call }
      # These generation tests exercise post-generation review with a reader
      # already accounted for. Reader outages and no-reader demo care are
      # exercised separately in mia_review_five_regressions_test.
      @original_care_guard = HouseholdFinance::ParticipantCare.method(:guard_when_unread)
      HouseholdFinance::ParticipantCare.define_singleton_method(:guard_when_unread) { |*, **_| nil }
      @original_reply_guard = Mia::ReplyGuard.singleton_class.instance_method(:call)
      Mia::ReplyGuard.singleton_class.define_method(:call) { |**_| Mia::ReplyGuard::Result.new([]) }
    end
    base.teardown do
      HouseholdFinance::ParticipantCare.define_singleton_method(:guard_when_unread, @original_care_guard)
      Mia::ReplyGuard.singleton_class.define_method(:call, @original_reply_guard)
      HouseholdFinance::MiaProviderAdmission.singleton_class.define_method(:with_slot, @original_guard_admission)
    end
  end
end
