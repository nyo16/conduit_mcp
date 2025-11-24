if Code.ensure_loaded?(PromEx) do
  defmodule ConduitMcp.PromExTest do
    use ExUnit.Case, async: true

    alias ConduitMcp.PromEx

    describe "event_metrics/1" do
      test "returns list of event metric groups" do
        opts = [otp_app: :test_app]
        metrics = PromEx.event_metrics(opts)

        assert is_list(metrics)
        assert length(metrics) == 5
      end

      test "requires otp_app option" do
        assert_raise KeyError, fn ->
          PromEx.event_metrics([])
        end
      end

      test "accepts duration_unit option" do
        opts = [otp_app: :test_app, duration_unit: :second]
        metrics = PromEx.event_metrics(opts)

        # Should not crash with custom duration unit
        assert is_list(metrics)
      end

      test "request metrics group contains counter and distribution" do
        opts = [otp_app: :test_app]
        [request_metrics | _] = PromEx.event_metrics(opts)

        assert request_metrics.group_name == :conduit_mcp_request_metrics
        assert length(request_metrics.metrics) == 2

        # Check counter
        counter = Enum.at(request_metrics.metrics, 0)
        assert counter.event_name == [:conduit_mcp, :request, :stop]
        assert :method in counter.tags
        assert :status in counter.tags

        # Check distribution
        distribution = Enum.at(request_metrics.metrics, 1)
        assert distribution.event_name == [:conduit_mcp, :request, :stop]
        # Measurement is converted to function when using unit conversion
        assert is_function(distribution.measurement, 1) or distribution.measurement == :duration
        assert :method in distribution.tags
        assert :status in distribution.tags
      end

      test "tool metrics group contains counter and distribution" do
        opts = [otp_app: :test_app]
        [_, tool_metrics | _] = PromEx.event_metrics(opts)

        assert tool_metrics.group_name == :conduit_mcp_tool_metrics
        assert length(tool_metrics.metrics) == 2

        counter = Enum.at(tool_metrics.metrics, 0)
        assert counter.event_name == [:conduit_mcp, :tool, :execute]
        assert :tool_name in counter.tags
        assert :status in counter.tags

        distribution = Enum.at(tool_metrics.metrics, 1)
        assert distribution.event_name == [:conduit_mcp, :tool, :execute]
        assert :tool_name in distribution.tags
      end

      test "resource metrics group contains counter and distribution" do
        opts = [otp_app: :test_app]
        [_, _, resource_metrics | _] = PromEx.event_metrics(opts)

        assert resource_metrics.group_name == :conduit_mcp_resource_metrics
        assert length(resource_metrics.metrics) == 2

        counter = Enum.at(resource_metrics.metrics, 0)
        assert counter.event_name == [:conduit_mcp, :resource, :read]
        assert :status in counter.tags

        distribution = Enum.at(resource_metrics.metrics, 1)
        assert distribution.event_name == [:conduit_mcp, :resource, :read]
        assert :status in distribution.tags
      end

      test "prompt metrics group contains counter and distribution" do
        opts = [otp_app: :test_app]
        [_, _, _, prompt_metrics | _] = PromEx.event_metrics(opts)

        assert prompt_metrics.group_name == :conduit_mcp_prompt_metrics
        assert length(prompt_metrics.metrics) == 2

        counter = Enum.at(prompt_metrics.metrics, 0)
        assert counter.event_name == [:conduit_mcp, :prompt, :get]
        assert :prompt_name in counter.tags
        assert :status in counter.tags

        distribution = Enum.at(prompt_metrics.metrics, 1)
        assert distribution.event_name == [:conduit_mcp, :prompt, :get]
        assert :prompt_name in distribution.tags
      end

      test "auth metrics group contains counter and distribution" do
        opts = [otp_app: :test_app]
        [_, _, _, _, auth_metrics] = PromEx.event_metrics(opts)

        assert auth_metrics.group_name == :conduit_mcp_auth_metrics
        assert length(auth_metrics.metrics) == 2

        counter = Enum.at(auth_metrics.metrics, 0)
        assert counter.event_name == [:conduit_mcp, :auth, :verify]
        assert :strategy in counter.tags
        assert :status in counter.tags

        distribution = Enum.at(auth_metrics.metrics, 1)
        assert distribution.event_name == [:conduit_mcp, :auth, :verify]
        assert :strategy in distribution.tags
      end

      test "uses correct metric prefix from otp_app" do
        opts = [otp_app: :my_custom_app]
        [request_metrics | _] = PromEx.event_metrics(opts)

        counter = Enum.at(request_metrics.metrics, 0)
        # Metric name should start with app prefix
        assert List.first(counter.name) == :my_custom_app
      end

      test "all distributions have appropriate histogram buckets" do
        opts = [otp_app: :test_app]
        metrics = PromEx.event_metrics(opts)

        # Check that all distributions have buckets defined
        Enum.each(metrics, fn event ->
          distribution = Enum.at(event.metrics, 1)
          assert is_list(distribution.reporter_options[:buckets])
          assert length(distribution.reporter_options[:buckets]) > 0
        end)
      end
    end

    describe "tag extraction" do
      test "tag extraction functions are called successfully" do
        # Tag extraction is tested indirectly through event_metrics
        # The functions are private but used in tag_values callbacks
        opts = [otp_app: :test_app]
        metrics = PromEx.event_metrics(opts)

        # Verify all metrics have tag_values functions defined
        Enum.each(metrics, fn event ->
          Enum.each(event.metrics, fn metric ->
            assert is_function(metric.tag_values, 1)
          end)
        end)
      end
    end

    describe "conditional compilation" do
      test "module exists when PromEx is loaded" do
        # If this test runs, PromEx is loaded
        assert Code.ensure_loaded?(ConduitMcp.PromEx)
        assert function_exported?(ConduitMcp.PromEx, :event_metrics, 1)
      end
    end
  end
else
  defmodule ConduitMcp.PromExTest do
    use ExUnit.Case, async: true

    test "PromEx plugin not available when PromEx not loaded" do
      refute Code.ensure_loaded?(ConduitMcp.PromEx)
    end
  end
end
