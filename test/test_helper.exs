# Compile test support files
Code.require_file("support/test_server.ex", __DIR__)
Code.require_file("support/telemetry_test.ex", __DIR__)
Code.require_file("support/test_rate_limiter.ex", __DIR__)

# Start the test rate limiter for rate limit tests
ConduitMcp.TestRateLimiter.start_link(clean_period: :timer.minutes(1))

ExUnit.start()
