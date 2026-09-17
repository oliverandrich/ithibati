defmodule Ithibati.Credo.BuildTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "the credo command recompiles a stale project check before using it", %{tmp_dir: dir} do
    aliases = Keyword.take(Mix.Project.config()[:aliases], [:credo])
    File.mkdir_p!(Path.join(dir, "lib"))

    # Load the task with the project, as a dependency task would be available before compilation.
    # Match Credo's loadpaths-only requirement without compiling the entire dependency tree.
    File.write!(Path.join(dir, "mix.exs"), """
    defmodule Probe.MixProject do
      use Mix.Project
      def project, do: [app: :credo_build_probe, version: "0.0.0", aliases: #{inspect(aliases)}]
    end

    defmodule Mix.Tasks.Credo do
      use Mix.Task
      @requirements ["loadpaths"]
      def run(_args) do
        if apply(Probe.Check, :current?, []) != true, do: Mix.raise("stale project check")
        Mix.shell().info("current project check")
      end
    end
    """)

    check = Path.join(dir, "lib/check.ex")
    File.write!(check, "defmodule Probe.Check do\n  def current?, do: false\nend\n")
    {output, status} = mix(dir, ["compile"])
    assert status == 0, output

    File.write!(check, "defmodule Probe.Check do\n  def current?, do: true\nend\n")
    {output, status} = mix(dir, ["credo", "--strict"])
    assert status == 0, output
    assert output =~ "current project check"
  end

  defp mix(dir, args) do
    System.cmd("mix", args,
      cd: dir,
      env: [{"MIX_ENV", "dev"}, {"MIX_BUILD_PATH", nil}, {"ERL_FLAGS", "+S 2:2"}],
      stderr_to_stdout: true
    )
  end
end
