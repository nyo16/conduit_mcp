# Start the test rate limiter for rate limit tests
ConduitMcp.TestRateLimiter.start_link(clean_period: :timer.minutes(1))

ExUnit.start()
