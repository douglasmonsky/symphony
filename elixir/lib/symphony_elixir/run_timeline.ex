defmodule SymphonyElixir.RunTimeline do
  @moduledoc """
  Builds the bounded, privacy-preserving inference and tool timeline shown by observability.

  Raw prompts, reasoning text, tool arguments, and tool output are intentionally excluded.
  """

  @record_limit 80
  @summary_max_bytes 320
  @tool_kinds ~w(commandexecution customtoolcall dynamictoolcall filechange functioncall mcptoolcall toolcall websearch)

  @spec record(map(), map(), map()) :: map()
  def record(entry, update, token_delta)
      when is_map(entry) and is_map(update) and is_map(token_delta) do
    entry
    |> record_tool_event(update)
    |> record_inference(update, token_delta)
  end

  @spec decode(term()) :: [map()]
  def decode(records) when is_list(records) do
    records
    |> Enum.map(&decode_record/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(-@record_limit)
  end

  def decode(_records), do: []

  @spec phase_counts([map()]) :: map()
  def phase_counts(records) when is_list(records) do
    Enum.reduce(records, %{}, fn record, counts ->
      phase = normalized_phase(map_value(record, :phase))
      kind = normalized_kind(map_value(record, :kind))

      Map.update(
        counts,
        phase,
        %{inference_calls: inference_increment(kind), tool_calls: tool_increment(kind)},
        fn current ->
          %{
            inference_calls: Map.get(current, :inference_calls, 0) + inference_increment(kind),
            tool_calls: Map.get(current, :tool_calls, 0) + tool_increment(kind)
          }
        end
      )
    end)
  end

  @spec decode_activity(term()) :: map()
  def decode_activity(activity) when is_map(activity) do
    Map.new(activity, fn {phase, counts} ->
      {normalized_phase(phase),
       %{
         inference_calls: non_negative_integer(map_value(counts, :inference_calls)),
         tool_calls: non_negative_integer(map_value(counts, :tool_calls))
       }}
    end)
  end

  def decode_activity(_activity), do: %{}

  defp record_tool_event(entry, %{payload: payload, timestamp: timestamp} = update)
       when is_map(payload) do
    method = map_value(payload, :method)
    item = payload |> map_value(:params, %{}) |> map_value(:item, %{})

    cond do
      method == "item/started" and tool_item?(item) ->
        put_tool_record(entry, item, update, timestamp, "running")

      method == "item/completed" and tool_item?(item) ->
        put_tool_record(entry, item, update, timestamp, tool_status(item, "completed"))

      update.event in [:tool_call_completed, :tool_call_failed, :unsupported_tool_call] ->
        params = map_value(payload, :params, %{})
        status = if update.event == :tool_call_completed, do: "completed", else: "failed"
        put_tool_record(entry, params, update, timestamp, status)

      true ->
        entry
    end
  end

  defp record_tool_event(entry, _update), do: entry

  defp put_tool_record(entry, item, update, timestamp, status) do
    source_id = optional_string(map_value(item, :id))
    records = Map.get(entry, :timeline, [])
    existing = Enum.find(records, &(source_id && map_value(&1, :source_id) == source_id))
    started_at = if existing, do: map_value(existing, :timestamp), else: iso8601(timestamp)
    {output_bytes, output_lines} = output_stats(item)

    phase = phase_for(entry, update)

    record = %{
      kind: "tool",
      phase: phase,
      timestamp: started_at || iso8601(timestamp),
      completed_at: if(status == "running", do: nil, else: iso8601(timestamp)),
      source_id: source_id,
      tool_name: tool_name(item),
      status: status,
      duration_ms: duration_ms(item, started_at, timestamp),
      exit_code: non_negative_integer_or_nil(map_value(item, :exitCode) || map_value(item, :exit_code)),
      output_bytes: output_bytes,
      output_lines: output_lines,
      truncated: map_value(item, :truncated) == true
    }

    entry
    |> Map.put(:timeline, upsert_record(records, existing, record))
    |> maybe_increment_activity(existing, phase, :tool_calls)
    |> maybe_put_timeline_trigger(record)
  end

  defp record_inference(entry, update, token_delta) do
    if positive_token_delta?(token_delta) do
      cached_input_tokens = non_negative_integer(map_value(token_delta, :cached_input_tokens))
      input_tokens = non_negative_integer(map_value(token_delta, :input_tokens))

      record = %{
        kind: "inference",
        phase: phase_for(entry, update),
        timestamp: iso8601(map_value(update, :timestamp)),
        trigger: Map.get(entry, :timeline_last_trigger, "initial prompt"),
        tokens: %{
          input_tokens: input_tokens,
          cached_input_tokens: cached_input_tokens,
          uncached_input_tokens: max(0, input_tokens - cached_input_tokens),
          output_tokens: non_negative_integer(map_value(token_delta, :output_tokens)),
          total_tokens: non_negative_integer(map_value(token_delta, :total_tokens))
        }
      }

      entry
      |> Map.update(:timeline, [record], &bounded_append(&1, record))
      |> increment_activity(record.phase, :inference_calls)
      |> Map.put(:timeline_last_trigger, "model continuation")
    else
      entry
    end
  end

  defp upsert_record(records, nil, record), do: bounded_append(records, record)

  defp upsert_record(records, existing, record) do
    Enum.map(records, fn candidate ->
      if candidate == existing do
        Map.put(record, :timestamp, map_value(existing, :timestamp))
      else
        candidate
      end
    end)
  end

  defp bounded_append(records, record) do
    (records ++ [record])
    |> Enum.take(-@record_limit)
  end

  defp maybe_put_timeline_trigger(entry, %{status: "running"}), do: entry

  defp maybe_put_timeline_trigger(entry, record) do
    Map.put(entry, :timeline_last_trigger, "tool result: #{record.tool_name}")
  end

  defp maybe_increment_activity(entry, nil, phase, key), do: increment_activity(entry, phase, key)
  defp maybe_increment_activity(entry, _existing, _phase, _key), do: entry

  defp increment_activity(entry, phase, key) do
    phase = normalized_phase(phase)
    initial_counts = Map.put(%{inference_calls: 0, tool_calls: 0}, key, 1)

    Map.update(entry, :timeline_activity, %{phase => initial_counts}, fn activity ->
      Map.update(activity, phase, initial_counts, fn counts ->
        Map.update(counts, key, 1, &(&1 + 1))
      end)
    end)
  end

  defp tool_item?(item) when is_map(item) do
    item
    |> map_value(:type, "")
    |> to_string()
    |> String.downcase()
    |> then(&(&1 in @tool_kinds))
  end

  defp tool_item?(_item), do: false

  defp tool_name(item) do
    type = map_value(item, :type, "")

    [
      map_value(item, :tool),
      map_value(item, :name),
      map_value(item, :server),
      if(String.downcase(to_string(type)) == "commandexecution", do: "command")
    ]
    |> Enum.find(&is_binary/1)
    |> case do
      nil -> "tool"
      name -> truncate(name)
    end
  end

  defp tool_status(item, fallback) do
    case map_value(item, :status) do
      status when is_binary(status) and status != "" -> truncate(status)
      _ -> fallback
    end
  end

  defp output_stats(item) do
    texts =
      [:aggregatedOutput, :output, :stdout, :stderr]
      |> Enum.map(&map_value(item, &1))
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    {
      Enum.sum(Enum.map(texts, &byte_size/1)) + max(0, length(texts) - 1),
      Enum.sum(Enum.map(texts, &(length(:binary.matches(&1, "\n")) + 1)))
    }
  end

  defp duration_ms(item, started_at, completed_at) do
    case map_value(item, :durationMs) || map_value(item, :duration_ms) do
      duration when is_integer(duration) and duration >= 0 ->
        duration

      _ ->
        with start when is_binary(start) <- started_at,
             {:ok, parsed_start, _offset} <- DateTime.from_iso8601(start),
             %DateTime{} = finish <- completed_at do
          max(0, DateTime.diff(finish, parsed_start, :millisecond))
        else
          _ -> nil
        end
    end
  end

  defp positive_token_delta?(token_delta) do
    Enum.any?(
      [:input_tokens, :cached_input_tokens, :output_tokens, :total_tokens],
      &(non_negative_integer(map_value(token_delta, &1)) > 0)
    )
  end

  defp phase_for(entry, update) do
    map_value(update, :phase) || Map.get(entry, :phase) || :intake
  end

  defp decode_record(record) when is_map(record) do
    case normalized_kind(map_value(record, :kind)) do
      "inference" ->
        %{
          kind: "inference",
          phase: normalized_phase(map_value(record, :phase)),
          timestamp: optional_string(map_value(record, :timestamp)),
          trigger: optional_summary(map_value(record, :trigger)),
          tokens: decode_tokens(map_value(record, :tokens, %{}))
        }

      "tool" ->
        %{
          kind: "tool",
          phase: normalized_phase(map_value(record, :phase)),
          timestamp: optional_string(map_value(record, :timestamp)),
          completed_at: optional_string(map_value(record, :completed_at)),
          tool_name: optional_summary(map_value(record, :tool_name)) || "tool",
          status: optional_summary(map_value(record, :status)) || "unknown",
          duration_ms: non_negative_integer_or_nil(map_value(record, :duration_ms)),
          exit_code: non_negative_integer_or_nil(map_value(record, :exit_code)),
          output_bytes: non_negative_integer(map_value(record, :output_bytes)),
          output_lines: non_negative_integer(map_value(record, :output_lines)),
          truncated: map_value(record, :truncated) == true
        }

      _ ->
        nil
    end
  end

  defp decode_record(_record), do: nil

  defp decode_tokens(tokens) when is_map(tokens) do
    input_tokens = non_negative_integer(map_value(tokens, :input_tokens))
    cached_input_tokens = min(input_tokens, non_negative_integer(map_value(tokens, :cached_input_tokens)))

    %{
      input_tokens: input_tokens,
      cached_input_tokens: cached_input_tokens,
      uncached_input_tokens: max(0, input_tokens - cached_input_tokens),
      output_tokens: non_negative_integer(map_value(tokens, :output_tokens)),
      total_tokens: non_negative_integer(map_value(tokens, :total_tokens))
    }
  end

  defp decode_tokens(_tokens),
    do: %{input_tokens: 0, cached_input_tokens: 0, uncached_input_tokens: 0, output_tokens: 0, total_tokens: 0}

  defp inference_increment("inference"), do: 1
  defp inference_increment(_kind), do: 0
  defp tool_increment("tool"), do: 1
  defp tool_increment(_kind), do: 0

  defp normalized_kind(kind) when kind in ["inference", :inference], do: "inference"
  defp normalized_kind(kind) when kind in ["tool", :tool], do: "tool"
  defp normalized_kind(_kind), do: nil

  defp normalized_phase(phase) when phase in [:intake, :implementation, :verification, :publication],
    do: phase

  defp normalized_phase(phase) when phase in ["intake", "implementation", "verification", "publication"],
    do: String.to_existing_atom(phase)

  defp normalized_phase(_phase), do: :intake

  defp map_value(map, key, default \\ nil)

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_value(_map, _key, default), do: default

  defp iso8601(%DateTime{} = timestamp), do: timestamp |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  defp iso8601(timestamp) when is_binary(timestamp), do: timestamp
  defp iso8601(_timestamp), do: nil

  defp optional_summary(value) when is_binary(value), do: truncate(value)
  defp optional_summary(_value), do: nil
  defp optional_string(value) when is_binary(value), do: value
  defp optional_string(_value), do: nil
  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: 0
  defp non_negative_integer_or_nil(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer_or_nil(_value), do: nil

  defp truncate(value) when byte_size(value) <= @summary_max_bytes, do: value

  defp truncate(value) do
    value
    |> truncate_utf8(@summary_max_bytes - byte_size("…"), [])
    |> Kernel.<>("…")
  end

  defp truncate_utf8(<<codepoint::utf8, rest::binary>>, remaining, accumulator) do
    encoded = <<codepoint::utf8>>

    if byte_size(encoded) > remaining do
      accumulator |> Enum.reverse() |> IO.iodata_to_binary()
    else
      truncate_utf8(rest, remaining - byte_size(encoded), [encoded | accumulator])
    end
  end
end
