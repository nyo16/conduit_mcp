# Compile test support files
Code.require_file("support/test_server.ex", __DIR__)
Code.require_file("support/telemetry_test.ex", __DIR__)

ExUnit.start()
