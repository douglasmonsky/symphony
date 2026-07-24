defmodule SymphonyElixir.CompletedRunStore do
  @moduledoc """
  Persists the dashboard's bounded completed-run history.

  The history contains only orchestration metadata and completed agent messages.
  Tool inputs, tool outputs, and raw protocol events are intentionally excluded.
  """

  require Logger

  alias SymphonyElixir.LogFile

  @default_limit 100
  @filename "completed-runs.json"
  @agent_message_limit 20
  @agent_message_max_bytes 20_000

  @spec load(pos_integer()) :: [map()]
  def load(limit \\ @default_limit) when is_integer(limit) and limit > 0 do
    case history_path() do
      nil ->
        []

      path ->
        with {:ok, contents} <- File.read(path),
             {:ok, records} when is_list(records) <- Jason.decode(contents) do
          records
          |> Enum.map(&decode_record/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.take(limit)
        else
          {:error, :enoent} ->
            []

          {:error, reason} ->
            Logger.warning("Unable to load completed-run history path=#{path}: #{inspect(reason)}")
            []

          _ ->
            Logger.warning("Ignoring invalid completed-run history path=#{path}")
            []
        end
    end
  end

  @spec persist([map()], pos_integer()) :: :ok | {:error, term()}
  def persist(records, limit \\ @default_limit)
      when is_list(records) and is_integer(limit) and limit > 0 do
    case history_path() do
      nil ->
        :ok

      path ->
        records = Enum.take(records, limit)
        temp_path = "#{path}.tmp-#{System.unique_integer([:positive])}"
        directory = Path.dirname(path)

        with :ok <- File.mkdir_p(directory),
             {:ok, json} <- Jason.encode(records, pretty: true),
             :ok <- File.write(temp_path, json <> "\n"),
             :ok <- File.chmod(temp_path, 0o600),
             :ok <- File.rename(temp_path, path) do
          :ok
        else
          {:error, reason} = error ->
            _ = File.rm(temp_path)
            Logger.warning("Unable to persist completed-run history path=#{path}: #{inspect(reason)}")
            error
        end
    end
  end

  defp history_path do
    case Application.get_env(:symphony_elixir, :completed_runs_file, :default) do
      false ->
        nil

      :default ->
        Application.get_env(:symphony_elixir, :log_file, LogFile.default_log_file())
        |> Path.dirname()
        |> Path.join(@filename)
        |> Path.expand()

      path when is_binary(path) ->
        Path.expand(path)
    end
  end

  defp decode_record(%{"identifier" => identifier, "tokens" => tokens} = record)
       when is_binary(identifier) and is_map(tokens) do
    with {:ok, decoded_tokens} <- decode_tokens(tokens),
         {:ok, runtime_seconds} <- non_negative_integer(record["runtime_seconds"]),
         {:ok, turn_count} <- non_negative_integer(record["turn_count"]),
         {:ok, agent_messages} <- decode_messages(record["agent_messages"]) do
      %{
        issue_id: optional_string(record["issue_id"]),
        identifier: identifier,
        issue_url: optional_string(record["issue_url"]),
        state: optional_string(record["state"]),
        worker_host: optional_string(record["worker_host"]),
        workspace_path: optional_string(record["workspace_path"]),
        session_id: optional_string(record["session_id"]),
        started_at: optional_string(record["started_at"]),
        completed_at: optional_string(record["completed_at"]),
        runtime_seconds: runtime_seconds,
        turn_count: turn_count,
        tokens: decoded_tokens,
        agent_messages: agent_messages,
        last_event: optional_string(record["last_event"]),
        last_message: optional_string(record["last_message"])
      }
    else
      _ -> nil
    end
  end

  defp decode_record(_record), do: nil

  defp decode_tokens(tokens) when is_map(tokens) do
    with {:ok, input_tokens} <- non_negative_integer(tokens["input_tokens"]),
         {:ok, cached_input_tokens} <- non_negative_integer(tokens["cached_input_tokens"]),
         {:ok, output_tokens} <- non_negative_integer(tokens["output_tokens"]),
         {:ok, total_tokens} <- non_negative_integer(tokens["total_tokens"]) do
      {:ok,
       %{
         input_tokens: input_tokens,
         cached_input_tokens: min(cached_input_tokens, input_tokens),
         output_tokens: output_tokens,
         total_tokens: total_tokens
       }}
    end
  end

  defp decode_messages(messages) when is_list(messages) do
    if Enum.all?(messages, &is_binary/1) do
      {:ok,
       messages
       |> Enum.take(-@agent_message_limit)
       |> Enum.map(&truncate_message/1)}
    else
      :error
    end
  end

  defp decode_messages(_messages), do: :error

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp non_negative_integer(_value), do: :error

  defp optional_string(nil), do: nil
  defp optional_string(value) when is_binary(value), do: value
  defp optional_string(_value), do: nil

  defp truncate_message(message) do
    truncate_utf8(message, @agent_message_max_bytes, [])
  end

  defp truncate_utf8(<<>>, _remaining, accumulator),
    do: accumulator |> Enum.reverse() |> IO.iodata_to_binary()

  defp truncate_utf8(<<codepoint::utf8, rest::binary>>, remaining, accumulator) do
    encoded = <<codepoint::utf8>>

    if byte_size(encoded) > remaining do
      accumulator |> Enum.reverse() |> IO.iodata_to_binary()
    else
      truncate_utf8(rest, remaining - byte_size(encoded), [encoded | accumulator])
    end
  end
end
