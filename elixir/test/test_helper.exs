# Real process and LiveView fixtures need scheduling time on busy developer hosts.
# Tests of bounded failure behavior keep their explicit, shorter timeouts.
ExUnit.start(assert_receive_timeout: 1_000)
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
