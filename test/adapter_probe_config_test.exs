defmodule Ithibati.AdapterProbeConfigTest do
  use ExUnit.Case, async: false

  @selectors ["ITHIBATI_USERS_KEY_TYPE", "ITHIBATI_SQLITE_UUID_STORAGE"]

  setup do
    original = Map.new(["ITHIBATI_ADAPTER_PROBE" | @selectors], &{&1, System.get_env(&1)})
    on_exit(fn -> System.put_env(original) end)
    System.put_env("ITHIBATI_ADAPTER_PROBE", "postgres")
    System.put_env(Map.new(@selectors, &{&1, nil}))
    :ok
  end

  for selector <- @selectors do
    @tag selector: selector
    test "blank #{selector} uses the default probe configuration", %{selector: selector} do
      defaults = Config.Reader.read!("config/adapter_probe.exs")
      System.put_env(selector, "")

      assert Config.Reader.read!("config/adapter_probe.exs") == defaults
    end

    @tag selector: selector
    test "blank #{selector} uses the default probe build directory", %{selector: selector} do
      default_path = Ithibati.MixProject.project()[:build_path]
      System.put_env(selector, "")

      assert Ithibati.MixProject.project()[:build_path] == default_path
    end
  end
end
