defmodule IthibatiEmailWeb.BrowserDriver do
  @moduledoc """
  Where the chromedriver the feature tests need comes from.

  Two places, and neither is `PATH`. GitHub's runner images ship a chromedriver matching their
  Chrome and point `CHROMEWEBDRIVER` at it, which is one version fewer to keep in step; everywhere
  else mise provides one, installed per machine because it has to match the Chrome that is here.

  Failing loudly is deliberate. Skipping the browser tests when no driver is found is the
  tempting alternative, and a suite that quietly stops covering anything is worse than one that
  stops.
  """

  @doc "The driver's path, or a raise that says how to get one."
  def path do
    case System.get_env("CHROMEWEBDRIVER") do
      nil -> from_mise()
      dir -> Path.join(dir, "chromedriver")
    end
  end

  defp from_mise do
    with mise when is_binary(mise) <- System.find_executable("mise"),
         {path, 0} <- System.cmd(mise, ["which", "chromedriver"], stderr_to_stdout: true) do
      String.trim(path)
    else
      _ -> raise no_driver()
    end
  end

  # The major is worked out rather than left to the reader: it is the one thing they cannot guess,
  # and getting it wrong produces a session error that names neither Chrome nor the driver.
  defp no_driver do
    """
    The browser tests need a chromedriver and there is none.

        mise use --path ../../mise.local.toml chromedriver@#{chrome_major() || "<your Chrome's major version>"}

    Into `mise.local.toml`, which is gitignored, because the version has to match the Chrome on
    *this* machine and Chrome updates itself. CI uses the runner's own through CHROMEWEBDRIVER.
    """
  end

  @chrome ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "google-chrome"]

  defp chrome_major do
    Enum.find_value(@chrome, fn candidate ->
      # `find_executable/1` resolves an absolute path as readily as a bare name, so one call covers
      # both shapes.
      with executable when is_binary(executable) <- System.find_executable(candidate),
           {output, 0} <- System.cmd(executable, ["--version"], stderr_to_stdout: true),
           [_, major] <- Regex.run(~r/\s(\d+)\./, output) do
        major
      else
        _ -> nil
      end
    end)
  end
end
