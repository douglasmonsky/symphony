defmodule SymphonyElixir.WorkerToolchain do
  @moduledoc """
  Supplies a deterministic worker PATH with the bundled `rg` fallback used by
  Codex Desktop on macOS.
  """

  @rg_fallbacks [
    "/Applications/ChatGPT.app/Contents/Resources/rg",
    "/opt/homebrew/bin/rg",
    "/usr/local/bin/rg"
  ]

  @spec path() :: String.t()
  def path do
    inherited = System.get_env("PATH", "")

    extra_directories =
      @rg_fallbacks
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.dirname/1)

    (String.split(inherited, ":", trim: true) ++ extra_directories)
    |> Enum.uniq()
    |> Enum.join(":")
  end

  @spec command_env() :: [{String.t(), String.t()}]
  def command_env, do: [{"PATH", path()}]

  @spec port_env() :: [{charlist(), charlist()}]
  def port_env, do: [{~c"PATH", String.to_charlist(path())}]
end
