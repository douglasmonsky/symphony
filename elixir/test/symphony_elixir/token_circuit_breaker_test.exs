defmodule SymphonyElixir.TokenCircuitBreakerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.TokenCircuitBreaker
  alias SymphonyElixir.Tracker.Issue

  @settings %{
    token_warn_total: 250_000,
    token_pause_no_change: 200_000,
    token_cache_ratio_pause: 10.0,
    token_compact_total: 500_000
  }

  test "warns on expensive docs-only work" do
    entry = entry(total: 260_000, input: 250_000, cached: 150_000)

    assert {:continue, [warning]} =
             TokenCircuitBreaker.evaluate(entry, @settings, true)

    assert warning =~ "Docs-only run"
    assert warning =~ "250000"
  end

  test "pauses when no files changed after the configured limit" do
    entry = entry(total: 210_000, input: 200_000, cached: 100_000)

    assert {:pause, reason, _warnings} =
             TokenCircuitBreaker.evaluate(entry, @settings, false)

    assert reason =~ "no files changed"
  end

  test "pauses on high cached-to-new ratio while operation is unchanged" do
    entry =
      entry(total: 300_000, input: 290_000, cached: 280_000)
      |> Map.put(:unchanged_operation_count, 3)

    assert {:pause, reason, _warnings} =
             TokenCircuitBreaker.evaluate(entry, @settings, true)

    assert reason =~ "cached:new context ratio"
    assert reason =~ "28.0"
  end

  test "reports an infinite ratio when all input is cached" do
    entry =
      entry(total: 300_000, input: 290_000, cached: 290_000)
      |> Map.put(:unchanged_operation_count, 2)

    assert {:pause, reason, _warnings} =
             TokenCircuitBreaker.evaluate(entry, @settings, true)

    assert reason =~ "infinite"
  end

  test "requires compaction before continuing beyond five hundred thousand" do
    entry = entry(total: 510_000, input: 450_000, cached: 300_000)

    assert {:pause, reason, _warnings} =
             TokenCircuitBreaker.evaluate(entry, @settings, true)

    assert reason =~ "explicit phase compaction required"

    assert {:continue, _warnings} =
             entry
             |> Map.put(:compaction_count, 1)
             |> TokenCircuitBreaker.evaluate(@settings, true)
  end

  test "recognizes a committed deliverable change against the declared publication base" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-token-circuit-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(workspace) end)
    File.mkdir_p!(workspace)
    git!(workspace, ["init", "-b", "main"])
    git!(workspace, ["config", "user.name", "Test User"])
    git!(workspace, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(workspace, "README.md"), "# Test\n")
    git!(workspace, ["add", "README.md"])
    git!(workspace, ["commit", "-m", "initial"])
    git!(workspace, ["branch", "release/docs"])
    git!(workspace, ["switch", "-c", "codex/docs"])
    File.write!(Path.join(workspace, "README.md"), "# Test\n\nDocumented.\n")
    git!(workspace, ["add", "README.md"])
    git!(workspace, ["commit", "-m", "docs: update readme"])

    issue = %Issue{
      id: "6",
      identifier: "GH-6",
      title: "Document behavior",
      description: "Open the pull request against `release/docs`."
    }

    assert Orchestrator.workspace_has_deliverable_change_for_test(workspace, issue)
  end

  defp git!(workspace, args) do
    assert {_output, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
  end

  defp entry(values) do
    %{
      issue: %{title: "Document autonomous verification", description: "Update README.md"},
      codex_total_tokens: Keyword.fetch!(values, :total),
      codex_input_tokens: Keyword.fetch!(values, :input),
      codex_cached_input_tokens: Keyword.fetch!(values, :cached),
      unchanged_operation_count: 0,
      compaction_count: 0
    }
  end
end
