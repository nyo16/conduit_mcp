defmodule ConduitMcp.Client.Policy.Decision do
  @moduledoc """
  The outcome of `ConduitMcp.Client.Policy.evaluate/4` (and its resource and
  prompt variants).

    * `:decision` - `:allow`, `:ask` (run the approver) or `:deny`.
    * `:source` - what produced it: a `:deny`, `:ask` or `:allow` rule, the
      fingerprint pin (`:pin`), or the `:default`.
    * `:rule_id` - the matching rule's id (`{list, index}` such as
      `{:deny, 0}`, or the id given with `{:rule, id, pattern}`); `nil` for
      `:pin` and `:default`. When several rules in the deciding list match,
      it is the first in list order.
    * `:reason` - a closed atom (safe for telemetry and logs):
      * `:deny_rule`, `:ask_rule`, `:allow_rule` - a rule of that list
        matched;
      * `:predicate_failed` - a deny or ask rule's function or argument
        predicate raised, exited, threw or returned a non-boolean, and the
        rule was taken as matching (fail closed);
      * `:no_approver` - an ask rule matched but no approver exists, so the
        decision is `:deny`;
      * `:definition_changed` - the tool's fingerprint differs from the one
        it was approved with (`source: :pin`);
      * `:no_rule` - nothing matched (`source: :default`);
      * `:out_of_scope` - the policy's `:scope` does not cover this kind of
        target, so it does not govern it (`decision: :allow`,
        `source: :default`).
  """

  @enforce_keys [:decision, :source, :reason]
  defstruct [:decision, :source, :reason, rule_id: nil]

  @type decision :: :allow | :ask | :deny
  @type source :: :deny | :ask | :allow | :default | :pin
  @type reason ::
          :deny_rule
          | :ask_rule
          | :allow_rule
          | :predicate_failed
          | :no_approver
          | :definition_changed
          | :no_rule
          | :out_of_scope

  @type t :: %__MODULE__{
          decision: decision(),
          source: source(),
          reason: reason(),
          rule_id: term()
        }
end
