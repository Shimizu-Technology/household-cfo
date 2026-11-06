# frozen_string_literal: true

# Contract/service tests isolate deterministic rules and persistence from the
# paid classifier. Semantic guard behavior is exercised by its own tests and
# the retained, once-run live evaluation corpus.
module ProposalGuardTestHelper
  def run
    with_proposal_guard { super }
  end

  def with_proposal_guard(allowed: true)
    result = Mia::PersonaSetup::ProposalGuard::Result.new(allowed ? [] : [ "unsupported" ])
    singleton = Mia::PersonaSetup::ProposalGuard.singleton_class
    original = singleton.instance_method(:call)
    singleton.define_method(:call) { |**_| result }
    yield
  ensure
    singleton.define_method(:call, original) if original
  end
end
