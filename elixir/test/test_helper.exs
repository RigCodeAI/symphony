ExUnit.start(exclude: if(System.get_env("SYMPHONY_RUN_VALIDATION_DOCKER") == "1", do: [], else: [:validation_docker]))
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
