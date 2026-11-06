# frozen_string_literal: true

# Generator/shape tests use a separate, explicitly passing classifier. The
# fail-closed wire and delivery integration are exercised in mia_reply_guard_test.
module ReplyGuardTestHelper
  def self.included(base)
    base.setup do
      @original_guard_admission = HouseholdFinance::MiaProviderAdmission.singleton_class.instance_method(:with_slot)
      HouseholdFinance::MiaProviderAdmission.singleton_class.define_method(:with_slot) { |**_, &block| block.call }
      @original_reply_guard = Mia::ReplyGuard.singleton_class.instance_method(:call)
      Mia::ReplyGuard.singleton_class.define_method(:call) { |**_| Mia::ReplyGuard::Result.new([]) }
    end
    base.teardown do
      Mia::ReplyGuard.singleton_class.define_method(:call, @original_reply_guard)
      HouseholdFinance::MiaProviderAdmission.singleton_class.define_method(:with_slot, @original_guard_admission)
    end
  end
end
