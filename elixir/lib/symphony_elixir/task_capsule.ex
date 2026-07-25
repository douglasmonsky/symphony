defmodule SymphonyElixir.TaskCapsule do
  @moduledoc """
  Builds compact, phase-specific task context for autonomous Codex workers.
  """

  alias SymphonyElixir.Tracker.Issue

  @publication_patterns [
    ~r/\b(pull request|pr)\b/i,
    ~r/\b(commit|push|publish|merge)\b/i,
    ~r/\b(agent-ready|agent-running|agent-blocked|human-review)\b/i
  ]

  @spec build(Issue.t(), Path.t(), keyword()) :: String.t()
  def build(%Issue{} = issue, workspace, opts \\ []) when is_binary(workspace) and is_list(opts) do
    description = issue.description || ""
    branch = Keyword.get(opts, :branch, "unknown")
    verification = Keyword.get(opts, :verification_command, "repository-defined focused checks")
    attempt = Keyword.get(opts, :attempt)

    """
    # Autonomous task capsule

    Objective: #{objective(description, issue.title)}
    Issue: #{issue.identifier} (#{issue.url || "no URL"})
    Attempt: #{attempt || 1}

    Allowed files:
    #{render_list(authorized_paths(issue))}

    Implementation constraints:
    #{render_list(section_items(description, ["scope"]))}

    Implementation acceptance criteria:
    #{render_list(implementation_criteria(description))}

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

    Current phase: implementation
    - Complete only the allowed file edits and bounded working-tree diff inspection.
    - Do not fetch, pull, commit, push, open or update a pull request, or call GitHub APIs.
    - Do not load publishing or blocked-procedure skills.
    - End this phase as soon as the working-tree diff is ready for host verification.
    """
    |> String.trim()
  end

  @spec publication_base(Issue.t()) :: String.t() | nil
  def publication_base(%Issue{description: description}) when is_binary(description) do
    case Regex.run(
           ~r/(?:pull request|pr).{0,40}(?:against|base(?:d)? on)\s+`([^`\n]+)`/i,
           description,
           capture: :all_but_first
         ) do
      [branch] -> String.trim(branch)
      _ -> nil
    end
  end

  def publication_base(%Issue{}), do: nil

  @spec authorized_paths(Issue.t()) :: [String.t()]
  def authorized_paths(%Issue{description: description}) when is_binary(description) do
    description
    |> section_items(["scope"])
    |> Enum.flat_map(&Regex.scan(~r/`([^`\n]+)`/, &1, capture: :all_but_first))
    |> List.flatten()
    |> Enum.filter(&path_like?/1)
    |> Enum.uniq()
    |> Enum.take(20)
  end

  def authorized_paths(%Issue{}), do: []

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

    Interpret this bounded result and inspect the local diff only where needed. Do not edit files,
    fetch, commit, push, call GitHub APIs, or rerun the final gate. Do not load publishing
    instructions yet. End after stating whether this exact verification result permits publication.
    """
    |> String.trim()
  end

  def phase_handoff(:publication, context) when is_map(context) do
    """
    # Publish-or-block phase

    Verification status: #{get_in(context, [:verification, :status]) || "unknown"}
    Pull request base: #{Map.get(context, :base_branch) || "repository default"}
    Changed paths:
    #{render_list(Map.get(context, :changed_paths, []))}

    Make only the publish-or-block judgment. Do not load skills, inspect additional files, edit,
    fetch, commit, push, or call GitHub APIs. Symphony owns the complete delivery transaction.

    End with exactly one single-line JSON declaration. For a ready result:
    SYMPHONY_DELIVERY: {"outcome":"ready","commit_message":"feat: concise message","pr_title":"Concise title","summary":"Reader-facing summary"}

    For a blocked result:
    SYMPHONY_DELIVERY: {"outcome":"blocked","reason":"Specific blocker"}
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

  defp implementation_criteria(description) do
    description
    |> section_items(["acceptance criteria"])
    |> Enum.reject(fn criterion ->
      Enum.any?(@publication_patterns, &String.match?(criterion, &1))
    end)
  end

  defp objective(description, fallback) do
    case section_items(description, ["objective"]) do
      [] -> fallback
      items -> Enum.join(items, " ")
    end
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
