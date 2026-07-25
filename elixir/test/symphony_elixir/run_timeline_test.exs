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

  test "normalizes malformed persisted records and activity" do
    assert RunTimeline.decode_activity(nil) == %{}

    assert RunTimeline.decode_activity(%{"future" => %{"inference_calls" => "bad"}}) == %{
             intake: %{inference_calls: 0, tool_calls: 0}
           }

    assert [
             %{
               phase: :intake,
               tokens: %{
                 input_tokens: 0,
                 cached_input_tokens: 0,
                 uncached_input_tokens: 0,
                 output_tokens: 0,
                 total_tokens: 0
               }
             }
           ] =
             RunTimeline.decode([
               %{
                 kind: "inference",
                 phase: "future",
                 timestamp: nil,
                 trigger: nil,
                 tokens: "malformed"
               }
             ])
  end

  test "records fallback tool events with bounded metadata" do
    timestamp = "2026-07-25T12:00:00Z"
    long_name = String.duplicate("é", 200)

    entry =
      %{phase: :implementation}
      |> RunTimeline.record(
        %{event: :notification, timestamp: nil, payload: "malformed"},
        zero_delta()
      )
      |> RunTimeline.record(
        %{
          event: :notification,
          timestamp: timestamp,
          payload: %{method: "item/completed", params: "malformed"}
        },
        zero_delta()
      )
      |> RunTimeline.record(
        %{
          event: :notification,
          timestamp: timestamp,
          payload: %{method: "item/completed", params: %{item: "malformed"}}
        },
        zero_delta()
      )
      |> RunTimeline.record(
        %{
          event: :notification,
          timestamp: timestamp,
          payload: %{
            method: "item/completed",
            params: %{item: %{type: "mcpToolCall", id: "fallback-status", status: nil}}
          }
        },
        zero_delta()
      )
      |> RunTimeline.record(
        %{
          event: :tool_call_completed,
          timestamp: timestamp,
          payload: %{params: %{type: "mcpToolCall", status: nil, durationMs: 7}}
        },
        zero_delta()
      )
      |> RunTimeline.record(
        %{
          event: :tool_call_failed,
          timestamp: nil,
          payload: %{params: %{type: "mcpToolCall", name: long_name, status: ""}}
        },
        zero_delta()
      )

    assert [status_fallback, fallback, bounded] = entry.timeline
    assert status_fallback.status == "completed"
    assert fallback.tool_name == "tool"
    assert fallback.status == "completed"
    assert fallback.duration_ms == 7
    assert fallback.timestamp == timestamp
    assert bounded.status == "failed"
    assert bounded.timestamp == nil
    assert String.ends_with?(bounded.tool_name, "…")
    assert byte_size(bounded.tool_name) <= 320
  end

  test "completing one tool preserves other running tool records" do
    started = ~U[2026-07-25 12:00:00Z]

    entry =
      Enum.reduce(["first", "second"], %{phase: :implementation}, fn id, current ->
        RunTimeline.record(
          current,
          %{
            event: :notification,
            timestamp: started,
            payload: %{
              method: "item/started",
              params: %{item: %{id: id, type: "mcpToolCall", name: id}}
            }
          },
          zero_delta()
        )
      end)

    completed =
      RunTimeline.record(
        entry,
        %{
          event: :notification,
          timestamp: DateTime.add(started, 1, :second),
          payload: %{
            method: "item/completed",
            params: %{item: %{id: "first", type: "mcpToolCall", name: "first"}}
          }
        },
        zero_delta()
      )

    assert Enum.map(completed.timeline, &{&1.tool_name, &1.status}) == [
             {"first", "completed"},
             {"second", "running"}
           ]
  end

  defp zero_delta do
    %{input_tokens: 0, cached_input_tokens: 0, output_tokens: 0, total_tokens: 0}
  end
end
