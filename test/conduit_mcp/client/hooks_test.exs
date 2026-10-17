defmodule ConduitMcp.Client.HooksTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.Client.Hooks

  def pre(_call, _ctx), do: :cont

  describe "compile/1" do
    test "orders each event global → server → tool, post and failure hooks reversed" do
      f2 = fn _call, _ctx -> :cont end
      f3 = fn _call, _result, _ctx -> :cont end
      specs = [{"fs/read", :tool}, {:all, :global}, {"fs/*", :server}, {"*", :global2}]

      hooks =
        Hooks.compile(
          pre_tool_call: for({m, id} <- specs, do: {m, f2, id: id}),
          post_tool_call: for({m, id} <- specs, do: {m, f3, id: :"post_#{id}"})
        )

      assert Enum.map(hooks.pre_tool_call, & &1.id) == [:global, :global2, :server, :tool]

      assert Enum.map(hooks.post_tool_call, & &1.id) ==
               [:post_tool, :post_server, :post_global2, :post_global]

      refute Hooks.empty?(hooks)
      assert Hooks.empty?(Hooks.compile([]))
    end

    test "default ids name the event and position; {Module, fun} is accepted" do
      hooks = Hooks.compile(pre_tool_call: [{:all, {__MODULE__, :pre}}, {:all, &pre/2}])
      assert Enum.map(hooks.pre_tool_call, & &1.id) == [{:pre_tool_call, 0}, {:pre_tool_call, 1}]
    end

    test "rejects invalid specs, naming the event" do
      f2 = fn _call, _ctx -> :cont end

      for {spec, message} <- [
            {[unknown: []], ~r/unknown hook event :unknown/},
            {[pre_tool_call: :nope], ~r/must be a list/},
            {[pre_tool_call: [{:all, fn _ -> :cont end}]], ~r/2-arity function/},
            {[post_tool_call: [{:all, f2}]], ~r/3-arity function/},
            {[pre_tool_call: [{:all, {__MODULE__, :missing}}]], ~r/is not exported/},
            {[pre_tool_call: [{:all, f2, on_error: :ignore}]],
             ~r/only allowed for post_tool_call/},
            {[pre_tool_call: [{:all, f2, timeout: 0}]], ~r/:timeout must be a positive integer/},
            {[pre_tool_call: [{:all, f2, bogus: 1}]], ~r/unknown option/},
            {[pre_tool_call: [{:all, f2, id: :a}, {:all, f2, id: :a}]], ~r/duplicate hook id :a/},
            {[pre_tool_call: [{"fs:x/read", f2}]], ~r/cannot contain/},
            {[pre_tool_call: [:not_a_hook]], ~r/expected \{matcher, fun\}/}
          ] do
        assert_raise ArgumentError, message, fn -> Hooks.compile(spec) end
      end
    end

    test "on_error: :ignore is accepted for post-hooks and failure hooks" do
      f3 = fn _a, _b, _ctx -> :cont end

      hooks =
        Hooks.compile(
          post_tool_call: [{:all, f3, on_error: :ignore}],
          tool_call_failed: [{:all, f3, on_error: :ignore}]
        )

      assert [%{on_error: :ignore}] = hooks.post_tool_call
    end

    test "resource and prompt matchers glob their own targets" do
      f2 = fn _uri, _ctx -> :cont end
      f3 = fn _name, _args, _ctx -> :cont end

      hooks =
        Hooks.compile(
          on_resource_read: [{"fs/file://*", f2}, {"fs/*", f2}],
          on_prompt_get: [{{"fs", ~r/^greet/}, f3}]
        )

      assert [%{level: 1}, %{level: 2}] = hooks.on_resource_read
      assert [%{matcher: {:regex, :prompt, _, _}}] = hooks.on_prompt_get
    end
  end
end
