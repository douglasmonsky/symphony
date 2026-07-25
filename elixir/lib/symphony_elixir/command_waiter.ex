defmodule SymphonyElixir.CommandWaiter do
  @moduledoc """
  Runs a verification command once without a PTY and returns a bounded result.

  Full output is streamed to a local artifact while only a compact diagnostic
  summary is retained for the caller.
  """

  @default_timeout_ms 3_600_000
  @default_relevant_line_limit 20
  @line_bytes 1_048_576

  alias SymphonyElixir.WorkerToolchain

  @type result :: %{
          command: String.t(),
          duration_ms: non_neg_integer(),
          exit_code: non_neg_integer() | nil,
          status: :passed | :failed | :timeout,
          passed_stages: [String.t()],
          failed_stages: [String.t()],
          relevant_lines: [String.t()],
          log_path: Path.t()
        }

  @spec run(Path.t(), String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(workspace, command, opts \\ [])
      when is_binary(workspace) and is_binary(command) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    line_limit = Keyword.get(opts, :relevant_line_limit, @default_relevant_line_limit)
    log_path = Keyword.get_lazy(opts, :log_path, fn -> default_log_path(workspace) end)

    with :ok <- File.mkdir_p(Path.dirname(log_path)),
         {:ok, log} <- File.open(log_path, [:write, :binary]),
         {:ok, executable} <- bash_executable() do
      started_at = System.monotonic_time(:millisecond)

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(command)],
            cd: String.to_charlist(workspace),
            env:
              [
                {~c"CI", ~c"1"},
                {~c"COLUMNS", ~c"160"},
                {~c"LINES", ~c"50"},
                {~c"TERM", ~c"dumb"}
              ] ++ WorkerToolchain.port_env(),
            line: @line_bytes
          ]
        )

      try do
        result =
          await_exit(port, log, started_at, timeout_ms, %{
            command: command,
            lines: [],
            log_path: log_path,
            line_limit: line_limit
          })

        {:ok, result}
      after
        File.close(log)
      end
    end
  end

  defp await_exit(port, log, started_at, timeout_ms, state) do
    remaining_ms = max(0, timeout_ms - (System.monotonic_time(:millisecond) - started_at))

    receive do
      {^port, {:data, {:eol, data}}} ->
        :ok = IO.binwrite(log, [data, "\n"])
        await_exit(port, log, started_at, timeout_ms, collect_line(state, data))

      {^port, {:data, {:noeol, data}}} ->
        :ok = IO.binwrite(log, data)
        await_exit(port, log, started_at, timeout_ms, collect_line(state, data))

      {^port, {:data, data}} when is_binary(data) ->
        :ok = IO.binwrite(log, data)
        await_exit(port, log, started_at, timeout_ms, collect_line(state, data))

      {^port, {:exit_status, exit_code}} ->
        build_result(state, started_at, exit_code, if(exit_code == 0, do: :passed, else: :failed))
    after
      remaining_ms ->
        Port.close(port)
        build_result(state, started_at, nil, :timeout)
    end
  end

  defp collect_line(state, data) do
    line = data |> IO.iodata_to_binary() |> String.trim_trailing()
    %{state | lines: [line | state.lines] |> Enum.take(state.line_limit * 4)}
  end

  defp build_result(state, started_at, exit_code, status) do
    lines = Enum.reverse(state.lines)

    %{
      command: state.command,
      duration_ms: max(0, System.monotonic_time(:millisecond) - started_at),
      exit_code: exit_code,
      status: status,
      passed_stages: passed_stages(lines),
      failed_stages: failed_stages(lines, status),
      relevant_lines: relevant_lines(lines, state.line_limit, status),
      log_path: state.log_path
    }
  end

  defp passed_stages(lines) do
    []
    |> maybe_stage(lines, ~r/\btests?, 0 failures\b/i, "tests")
    |> maybe_stage(lines, ~r/Total errors:\s*0/i, "dialyzer")
    |> maybe_stage(lines, ~r/passed successfully/i, "quality gate")
  end

  defp failed_stages(_lines, :passed), do: []

  defp failed_stages(lines, _status) do
    lines
    |> Enum.filter(&String.match?(&1, ~r/(fail|error|timeout)/i))
    |> Enum.take(5)
  end

  defp relevant_lines(lines, limit, :passed), do: Enum.take(lines, -limit)

  defp relevant_lines(lines, limit, _status) do
    failures = Enum.filter(lines, &String.match?(&1, ~r/(fail|error|assert|timeout|\*\*)/i))
    if failures == [], do: Enum.take(lines, -limit), else: Enum.take(failures, limit)
  end

  defp maybe_stage(stages, lines, pattern, stage) do
    if Enum.any?(lines, &String.match?(&1, pattern)), do: stages ++ [stage], else: stages
  end

  defp default_log_path(workspace) do
    workspace_key =
      :crypto.hash(:sha256, workspace)
      |> Base.url_encode64(padding: false)
      |> String.slice(0, 12)

    Path.join([
      System.tmp_dir!(),
      "symphony-verification",
      "#{Path.basename(workspace)}-#{workspace_key}",
      "verification-#{System.system_time(:millisecond)}.log"
    ])
  end

  defp bash_executable do
    case System.find_executable("bash") do
      nil -> {:error, :bash_not_found}
      path -> {:ok, path}
    end
  end
end
