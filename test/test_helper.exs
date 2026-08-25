# Start the test rate limiter for rate limit tests.
# Matched so a start failure surfaces here rather than as an opaque
# `:noproc` inside an unrelated rate-limit test.
{:ok, _pid} = ConduitMcp.TestRateLimiter.start_link(clean_period: :timer.minutes(1))

# The 100 ms default is the tightest window in the suite and is relied on by
# ~20 `assert_receive` call sites; 500 ms keeps them honest on a loaded runner.
#
# `refute_receive_timeout` is stated rather than left implicit: raising only
# the assert side leaves every `refute_receive` on a window 5x tighter than its
# siblings, silently. That is deliberate here - the four `refute_receive` sites
# each sit behind a hard barrier (a `Task.await` or a prior `assert_receive`),
# so they do not need the longer window and paying it would add 2 s to the run.
ExUnit.start(assert_receive_timeout: 500, refute_receive_timeout: 100)
