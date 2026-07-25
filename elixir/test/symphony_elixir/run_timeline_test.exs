defmodule SymphonyElixir.RunTimelineTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RunTimeline

  test "records inference deltas and completed command metadata without output content" do
    started_at = ~U[2026-07-25 12:00:00.000Z]
    completed_at = DateTime.add(started_at, 1_250, :millisecond)

    entry =
      %{phase: :implementation, timeline: []}
      |> RunTimeline.record(
        %{
          event: :notification,
          timestamp: started_at,
          payload: %{
            "method" => "item/started",
            "params" => %{
              "item" => %{
                "id" => "command-1",
                "type" => "commandExecution",
                "command" => "curl -H token=supersecret https://user:pass@example.test"
              }
            }
          }
        },
        zero_delta()
      )
      |> RunTimeline.record(
        %{
          event: :notification,
          timestamp: completed_at,
          payload: %{
            "method" => "item/completed",
            "params" => %{
              "item" => %{
                "id" => "command-1",
                "type" => "commandExecution",
                "status" => "completed",
                "command" => "curl -H token=supersecret https://user:pass@example.test",
                "aggregatedOutput" => "private first line\nprivate second line",
                "exitCode" => 0,
                "truncated" => true
              }
            }
          }
        },
        zero_delta()
      )
      |> RunTimeline.record(
        %{
          event: :notification,
          timestamp: DateTime.add(completed_at, 10, :millisecond),
          payload: %{"method" => "thread/tokenUsage/updated"}
        },
        %{
          input_tokens: 20_000,
          cached_input_tokens: 14_000,
          output_tokens: 200,
          total_tokens: 20_200
        }
      )

    assert [tool, inference] = entry.timeline
    assert tool.kind == "tool"
    assert tool.tool_name == "command"
    assert tool.status == "completed"
    assert tool.duration_ms == 1_250
    assert tool.exit_code == 0
    assert tool.output_lines == 2
    assert tool.output_bytes == byte_size("private first line\nprivate second line")
    assert tool.truncated
    refute inspect(entry.timeline) =~ "private first line"
    refute inspect(entry.timeline) =~ "supersecret"
    refute inspect(entry.timeline) =~ "user:pass"
    refute inspect(entry.timeline) =~ "example.test"

    assert inference.kind == "inference"
    assert inference.phase == :implementation
    assert inference.trigger == "tool result: command"
    assert inference.tokens.uncached_input_tokens == 6_000
    assert inference.tokens.cached_input_tokens == 14_000
    assert inference.tokens.output_tokens == 200
    assert inference.tokens.total_tokens == 20_200
  end

  test "decodes legacy-safe records and counts phase activity" do
    decoded =
      RunTimeline.decode([
        %{
          "kind" => "inference",
          "phase" => "verification",
          "timestamp" => "2026-07-25T12:00:00Z",
          "tokens" => %{
            "input_tokens" => 10,
            "cached_input_tokens" => 30,
            "output_tokens" => 2,
            "total_tokens" => 12
          }
        },
        %{
          "kind" => "tool",
          "phase" => "verification",
          "tool_name" => "serena.find_symbol",
          "argument_summary" => "private@example.test --token arbitrary-secret",
          "status" => "completed",
          "output_bytes" => 50,
          "output_lines" => 3
        },
        %{"kind" => "reasoning", "text" => "must not be retained"},
        "invalid"
      ])

    assert [inference, tool] = decoded
    assert inference.tokens.cached_input_tokens == 10
    assert inference.tokens.uncached_input_tokens == 0
    assert tool.tool_name == "serena.find_symbol"
    refute Map.has_key?(tool, :argument_summary)

    assert RunTimeline.phase_counts(decoded) == %{
             verification: %{inference_calls: 1, tool_calls: 1}
           }

    assert RunTimeline.decode(nil) == []
  end

  test "bounds retained records while cumulative phase activity keeps increasing" do
    entry =
      Enum.reduce(1..100, %{phase: :implementation}, fn index, current ->
        phase = if index <= 50, do: :implementation, else: :verification

        RunTimeline.record(
          %{current | phase: phase},
          %{
            event: :notification,
            timestamp: DateTime.add(~U[2026-07-25 12:00:00Z], index, :second),
            payload: %{"method" => "thread/tokenUsage/updated"}
          },
          %{input_tokens: 1, cached_input_tokens: 0, output_tokens: 0, total_tokens: 1}
        )
      end)

    assert length(entry.timeline) == 80

    assert entry.timeline_activity == %{
             implementation: %{inference_calls: 50, tool_calls: 0},
             verification: %{inference_calls: 50, tool_calls: 0}
           }
  end

  test "records supported tool shapes without retaining their payloads" do
    entry =
      Enum.reduce(["fileChange", "webSearch", "mcpToolCall"], %{phase: :implementation}, fn type, current ->
        RunTimeline.record(
          current,
          %{
            event: :notification,
            timestamp: ~U[2026-07-25 12:00:00Z],
            payload: %{
              "method" => "item/completed",
              "params" => %{
                "item" => %{
                  "id" => type,
                  "type" => type,
                  "name" => type,
                  "arguments" => %{"query" => "private@example.test", "patch" => "private change"},
                  "status" => "completed"
                }
              }
            }
          },
          zero_delta()
        )
      end)

    assert Enum.map(entry.timeline, & &1.tool_name) == ["fileChange", "webSearch", "mcpToolCall"]
    assert entry.timeline_activity.implementation.tool_calls == 3
    refute inspect(entry.timeline) =~ "private@example.test"
    refute inspect(entry.timeline) =~ "private change"
  end

  defp zero_delta do
    %{input_tokens: 0, cached_input_tokens: 0, output_tokens: 0, total_tokens: 0}
  end
end
