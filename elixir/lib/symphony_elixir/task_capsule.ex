defmodule SymphonyElixir.TaskCapsule do
  @moduledoc """
  Builds compact, phase-specific task context for autonomous Codex workers.
  """

  alias SymphonyElixir.Tracker.Issue

  @section_names ["scope", "acceptance criteria", "validation", "test plan", "testing"]

  @spec build(Issue.t(), Path.t(), keyword()) :: String.t()
  def build(%Issue{} = issue, workspace, opts \\ []) when is_binary(workspace) and is_list(opts) do
    description = issue.description || ""
    branch = Keyword.get(opts, :branch, "unknown")
    verification = Keyword.get(opts, :verification_command, "repository-defined focused checks")
    attempt = Keyword.get(opts, :attempt)

    """
    # Autonomous task capsule

    Objective: #{issue.title}
    Issue: #{issue.identifier} (#{issue.url || "no URL"})
    Attempt: #{attempt || 1}

    Allowed files:
    #{render_list(allowed_files(description))}

    Acceptance criteria:
    #{render_list(section_items(description, ["acceptance criteria"]))}

    Scoped requirements:
    #{render_list(section_items(description, @section_names))}

    Verification:
    - #{verification}

    Repository facts:
    - Workspace: #{workspace}
    - Branch: #{branch}
    - Read applicable AGENTS.md guidance before editing.
    - `rg` is available; use it for bounded discovery.

    Lifecycle contract:
    - Symphony owns branch preparation, lifecycle labels, workpad updates, verification execution,
      verification artifacts, and final lifecycle cleanup.
    - You own investigation, implementation judgment, diff quality, verification interpretation,
      and the publish-or-block decision.
    - Do not run the final verification command yourself.
    - Do not mutate lifecycle labels or create progress comments.
    """
    |> String.trim()
  end

  @spec phase_handoff(atom(), map()) :: String.t()
  def phase_handoff(:verification, context) when is_map(context) do
    """
    # Verification interpretation phase

    Changed paths:
    #{render_list(Map.get(context, :changed_paths, []))}

    Rationale:
    #{Map.get(context, :rationale, "Implementation phase completed.")}

    Diff status: #{Map.get(context, :diff_status, "unknown")}

    Host verification result:
    #{render_verification(Map.get(context, :verification, %{}))}

    Interpret this bounded result and inspect the local diff only where needed. Do not rerun the
    final gate. Do not load publishing instructions yet.
    """
    |> String.trim()
  end

  def phase_handoff(:publication, context) when is_map(context) do
    """
    # Publish-or-block phase

    Verification status: #{get_in(context, [:verification, :status]) || "unknown"}
    Changed paths:
    #{render_list(Map.get(context, :changed_paths, []))}

    Load `.codex/skills/push/SKILL.md` only for commit, push, and PR mechanics. The host
    verification above is authoritative: do not run its validation step or launch the final
    gate again.

    If verification passed, publish exactly the changed paths with
    `/Users/Monsky/.codex-symphony/bin/symphony-git publish <conventional-commit-message> <path>...`,
    then open or update the PR against the base branch required by the issue. If verification
    failed or a true external blocker remains, preserve the workspace and report BLOCKED.
    Symphony will perform lifecycle labels, workpad evidence attachment, and final cleanup after
    the declared result.

    End the final response with exactly one declaration:
    SYMPHONY_OUTCOME: READY
    or
    SYMPHONY_OUTCOME: BLOCKED
    """
    |> String.trim()
  end

  defp section_items(description, names) do
    sections = parse_sections(description)

    names
    |> Enum.flat_map(&Map.get(sections, &1, []))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(20)
  end

  defp allowed_files(description) do
    description
    |> section_items(["scope"])
    |> Enum.flat_map(&Regex.scan(~r/`([^`\n]+)`/, &1, capture: :all_but_first))
    |> List.flatten()
    |> Enum.filter(&path_like?/1)
    |> Enum.uniq()
    |> Enum.take(20)
  end

  defp path_like?(value) do
    not String.contains?(value, " ") and
      (String.contains?(value, "/") or String.match?(value, ~r/\.[A-Za-z0-9]+$/))
  end

  defp parse_sections(description) do
    description
    |> String.split("\n")
    |> Enum.reduce({nil, %{}}, fn line, {current, sections} ->
      case Regex.run(~r/^[#]{1,3}\s+(.+?)\s*$/, String.trim(line), capture: :all_but_first) do
        [heading] ->
          normalized = heading |> String.downcase() |> String.trim()
          {normalized, Map.put_new(sections, normalized, [])}

        _ when is_binary(current) ->
          {current, Map.update!(sections, current, &(&1 ++ [strip_list_marker(line)]))}

        _ ->
          {current, sections}
      end
    end)
    |> elem(1)
  end

  defp strip_list_marker(line), do: Regex.replace(~r/^\s*[-*]\s+/, line, "")

  defp render_list([]), do: "- Not explicitly constrained."
  defp render_list(items), do: Enum.map_join(items, "\n", &"- #{&1}")

  defp render_verification(result) do
    [
      "Command: #{Map.get(result, :command, "unknown")}",
      "Status: #{Map.get(result, :status, "unknown")}",
      "Duration ms: #{Map.get(result, :duration_ms, 0)}",
      "Exit code: #{inspect(Map.get(result, :exit_code))}",
      "Passed stages: #{Enum.join(Map.get(result, :passed_stages, []), ", ")}",
      "Failed stages: #{Enum.join(Map.get(result, :failed_stages, []), ", ")}",
      "Relevant lines:\n#{render_list(Map.get(result, :relevant_lines, []))}",
      "Full log artifact: #{Map.get(result, :log_path, "unavailable")}"
    ]
    |> Enum.join("\n")
  end
end
