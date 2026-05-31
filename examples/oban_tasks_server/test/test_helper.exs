# The smoke test boots the full app on a fixed port; exclude it by default so
# a cold `mix test` doesn't flunk. Run it with `mix test --include integration`.
ExUnit.configure(exclude: [:integration])
ExUnit.start()
