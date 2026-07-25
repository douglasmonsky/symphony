defmodule SymphonyElixir.TokenCircuitBreaker do
  @moduledoc """
  Evaluates autonomous-run token limits without requiring a model response.
  """

  @type decision :: {:continue, [String.t()]} | {:pause, String.t(), [String.t()]}

  @spec evaluate(map(), map(), boolean()) :: decision()
  def evaluate(entry, settings, files_changed?)
      when is_map(entry) and is_map(settings) and is_boolean(files_changed?) do
    total = Map.get(entry, :codex_total_tokens, 0)
    input = Map.get(entry, :codex_input_tokens, 0)
    cached = min(Map.get(entry, :codex_cached_input_tokens, 0), input)
    new_context = max(0, input - cached)
    ratio = if new_context == 0, do: :infinity, else: cached / new_context
    unchanged_operation_count = Map.get(entry, :unchanged_operation_count, 0)
    compaction_count = Map.get(entry, :compaction_count, 0)

    warnings = warnings(entry, total, settings)
    reason = pause_reason(total, ratio, unchanged_operation_count, compaction_count, settings, files_changed?)

    if is_binary(reason) do
      {:pause, reason, warnings}
    else
      {:continue, warnings}
    end
  end

  defp pause_reason(total, ratio, unchanged_count, compaction_count, settings, files_changed?) do
    cond do
      total >= settings.token_pause_no_change and not files_changed? ->
        "no files changed after #{total} processed tokens (limit #{settings.token_pause_no_change})"

      ratio_exceeded?(ratio, settings.token_cache_ratio_pause) and unchanged_count >= 2 ->
        "cached:new context ratio #{format_ratio(ratio)} exceeded " <>
          "#{settings.token_cache_ratio_pause}:1 while operation was unchanged"

      total >= settings.token_compact_total and compaction_count == 0 ->
        "explicit phase compaction required before continuing beyond " <>
          "#{settings.token_compact_total} processed tokens"

      true ->
        nil
    end
  end

  defp warnings(entry, total, settings) do
    if docs_only?(entry) and total >= settings.token_warn_total do
      ["Docs-only run has processed #{total} tokens (warning threshold #{settings.token_warn_total})."]
    else
      []
    end
  end

  defp docs_only?(entry) do
    issue = Map.get(entry, :issue, %{})
    text = "#{Map.get(issue, :title, "")}\n#{Map.get(issue, :description, "")}" |> String.downcase()

    String.contains?(text, ["document", "docs", "readme", "agents.md", "markdown"])
  end

  defp ratio_exceeded?(:infinity, _threshold), do: true
  defp ratio_exceeded?(ratio, threshold), do: ratio > threshold

  defp format_ratio(:infinity), do: "infinite"
  defp format_ratio(ratio), do: :erlang.float_to_binary(ratio, decimals: 1)
end
